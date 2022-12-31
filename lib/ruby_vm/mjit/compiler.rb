require 'ruby_vm/mjit/assembler'
require 'ruby_vm/mjit/block_stub'
require 'ruby_vm/mjit/code_block'
require 'ruby_vm/mjit/context'
require 'ruby_vm/mjit/exit_compiler'
require 'ruby_vm/mjit/insn_compiler'
require 'ruby_vm/mjit/instruction'
require 'ruby_vm/mjit/jit_state'

module RubyVM::MJIT
  # Compilation status
  KeepCompiling = :KeepCompiling
  CantCompile = :CantCompile
  EndBlock = :EndBlock

  # Ruby constants
  Qnil = Fiddle::Qnil
  Qundef = Fiddle::Qundef

  # Callee-saved registers
  # TODO: support using r12/r13 here
  EC  = :r14
  CFP = :r15
  SP  = :rbx

  class Compiler
    attr_accessor :write_pos

    def self.decode_insn(encoded)
      INSNS.fetch(C.rb_vm_insn_decode(encoded))
    end

    # @param mem_block [Integer] JIT buffer address
    # @param mem_size  [Integer] JIT buffer size
    def initialize(mem_block, mem_size)
      @cb = CodeBlock.new(mem_block: mem_block, mem_size: mem_size / 2)
      @ocb = CodeBlock.new(mem_block: mem_block + mem_size / 2, mem_size: mem_size / 2, outlined: true)
      @exit_compiler = ExitCompiler.new
      @insn_compiler = InsnCompiler.new(@ocb)
    end

    # Compile an ISEQ from its entry point.
    # @param iseq `RubyVM::MJIT::CPointer::Struct_rb_iseq_t`
    # @param cfp `RubyVM::MJIT::CPointer::Struct_rb_control_frame_t`
    def compile(iseq, cfp)
      # TODO: Support has_opt
      return if iseq.body.param.flags.has_opt

      asm = Assembler.new
      asm.comment("Block: #{iseq.body.location.label}@#{C.rb_iseq_path(iseq)}:#{iseq.body.location.first_lineno}")
      compile_prologue(asm)
      compile_block(asm, jit: JITState.new(iseq:, cfp:))
      iseq.body.jit_func = @cb.write(asm)
    rescue Exception => e
      $stderr.puts e.full_message # TODO: check verbose
    end

    # Continue compilation from a stub.
    # @param stub [RubyVM::MJIT::BlockStub]
    # @param cfp `RubyVM::MJIT::CPointer::Struct_rb_control_frame_t`
    # @return [Integer] The starting address of a compiled stub
    def stub_hit(stub, cfp)
      # Update cfp->pc for `jit.at_current_insn?`
      cfp.pc = stub.pc

      # Compile the jump target
      new_addr = Assembler.new.then do |asm|
        jit = JITState.new(iseq: stub.iseq, cfp:)
        index = (stub.pc - stub.iseq.body.iseq_encoded.to_i) / C.VALUE.size
        compile_block(asm, jit:, index:, ctx: stub.ctx)
        @cb.write(asm)
      end

      # Re-generate the jump source
      @cb.with_addr(stub.addr) do
        asm = Assembler.new
        asm.comment('regenerate block stub')
        asm.jmp(new_addr)
        @cb.write(asm)
      end
      new_addr
    end

    private

    # Callee-saved: rbx, rsp, rbp, r12, r13, r14, r15
    # Caller-saved: rax, rdi, rsi, rdx, rcx, r8, r9, r10, r11
    #
    # @param asm [RubyVM::MJIT::Assembler]
    def compile_prologue(asm)
      asm.comment('MJIT entry')

      # Save callee-saved registers used by JITed code
      asm.push(CFP)
      asm.push(EC)
      asm.push(SP)

      # Move arguments EC and CFP to dedicated registers
      asm.mov(EC, :rdi)
      asm.mov(CFP, :rsi)

      # Load sp to a dedicated register
      asm.mov(SP, [CFP, C.rb_control_frame_t.offsetof(:sp)]) # rbx = cfp->sp
    end

    # @param asm [RubyVM::MJIT::Assembler]
    def compile_block(asm, jit:, index: 0, ctx: Context.new)
      iseq = jit.iseq
      while index < iseq.body.iseq_size
        insn = self.class.decode_insn(iseq.body.iseq_encoded[index])
        jit.pc = (iseq.body.iseq_encoded + index).to_i

        case compile_insn(jit, ctx, asm, insn)
        when EndBlock
          break
        when CantCompile
          @exit_compiler.compile_exit(jit, ctx, asm)
          break
        end
        index += insn.len
      end
    end

    # @param jit [RubyVM::MJIT::JITState]
    # @param ctx [RubyVM::MJIT::Context]
    # @param asm [RubyVM::MJIT::Assembler]
    def compile_insn(jit, ctx, asm, insn)
      asm.incr_counter(:mjit_insns_count)
      asm.comment("Insn: #{insn.name}")

      case insn.name
      # nop
      # getlocal
      # setlocal
      # getblockparam
      # setblockparam
      # getblockparamproxy
      # getspecial
      # setspecial
      # getinstancevariable
      # setinstancevariable
      # getclassvariable
      # setclassvariable
      # opt_getconstant_path
      # getconstant
      # setconstant
      # getglobal
      # setglobal
      when :putnil then @insn_compiler.putnil(jit, ctx, asm)
      # putself
      when :putobject then @insn_compiler.putobject(jit, ctx, asm)
      # putspecialobject
      # putstring
      # concatstrings
      # anytostring
      # toregexp
      # intern
      # newarray
      # newarraykwsplat
      # duparray
      # duphash
      # expandarray
      # concatarray
      # splatarray
      # newhash
      # newrange
      # pop
      # dup
      # dupn
      # swap
      # opt_reverse
      # topn
      # setn
      # adjuststack
      # defined
      # checkmatch
      # checkkeyword
      # checktype
      # defineclass
      # definemethod
      # definesmethod
      # send
      # opt_send_without_block
      # objtostring
      # opt_str_freeze
      # opt_nil_p
      # opt_str_uminus
      # opt_newarray_max
      # opt_newarray_min
      # invokesuper
      # invokeblock
      when :leave then @insn_compiler.leave(jit, ctx, asm)
      # throw
      # jump
      # branchif
      # branchunless
      # branchnil
      # once
      # opt_case_dispatch
      # opt_plus
      # opt_minus
      # opt_mult
      # opt_div
      # opt_mod
      # opt_eq
      # opt_neq
      when :opt_lt then @insn_compiler.opt_lt(jit, ctx, asm)
      # opt_le
      # opt_gt
      # opt_ge
      # opt_ltlt
      # opt_and
      # opt_or
      # opt_aref
      # opt_aset
      # opt_aset_with
      # opt_aref_with
      # opt_length
      # opt_size
      # opt_empty_p
      # opt_succ
      # opt_not
      # opt_regexpmatch2
      # invokebuiltin
      # opt_invokebuiltin_delegate
      # opt_invokebuiltin_delegate_leave
      when :getlocal_WC_0 then @insn_compiler.getlocal_WC_0(jit, ctx, asm)
      else CantCompile
      end
    end

    # vm_core.h: pathobj_path
    def pathobj_path(pathobj)
      if pathobj.is_a?(String)
        pathobj
      else
        pathobj.first
      end
    end
  end
end
