-- Z80 Single Step Debugger/Monitor
-- (c) Copyright 2015 Rob Probin.
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--
-- http://robprobin.com
-- https://github.com/robzed/LuaZ80
--
-- LICENSE NOTES
-- =============
-- Since this is Lua code (that generates more Lua code, so is pretty dependant
-- on a Lua interpreter), the requirement in the GPL to share does not seem
-- overly onerous/burdensome/difficult because you'll be distributing the Lua code
-- along with any product anyway. I considered MIT, ZLib, BSD, Apache licenses as
-- well but the GPL appeared to 'encourage' sharing. 
--
-- I'm quite willing to consider a different license if you have a specific 
-- use-case that would benefit - even if part of the (Lua or other) source 
-- would be closed or licensed under a non-open source license.

--
-- NOTES:
-- =====
-- 
-- This file is not built for speed, it is intended to be simple & fast to write
-- and run only occasionlly.

require("lua_z80")
require("z80_ss_debug")
require("Z80_assembler")

local function get_state(jit, cpu)
    
    return {
        
        -- we only check the 'user-visibie' registers here, not various
        -- internal registers.
        reg = {
            PC = cpu.PC,
            IX = cpu.IX,
            IY = cpu.IY,
            SP = cpu.SP,
            I = cpu.I,
            R = cpu.R,
            
            -- main registers
            A = cpu.A,
            F = cpu:get_F(),    -- always calculate F
            H = cpu.H,
            L = cpu.L,
            B = cpu.B,
            C = cpu.C,
            D = cpu.D,
            E = cpu.E,

            -- alternative 'shadow' registers
            -- we don't have access to the CPU flip flop directly
            A_ = cpu.A_,
            F_ = cpu.F_, 
            H_ = cpu.H_, 
            L_ = cpu.L_, 
            B_ = cpu.B_, 
            C_ = cpu.C_, 
            D_ = cpu.D_, 
            E_ = cpu.E_, 
            
            -- interrupt flags
            IFF1 = cpu.IFF1, -- this on effects maskable interrupts
            IFF2 = cpu.IFF2, -- this one is readible (ld a,i/ld a,r -> P/Ov)
            -- interrupt mode flip flops
            -- IMFa=0, IMFb=0 - Interrupt mode 0. This is an 8080-compatible interrupt mode.
            -- IMFa=0, IMFb=1 - Not used.
            -- IMFa=1, IMFb=0 - Interrupt mode 1. In this mode CPU jumps to location 0038h for interrupt processing.
            -- IMFa=1, IMFb=1 - Interrupt mode 2. In this mode CPU jumps to location, which high-order address is taken from I register, and low order address is supplied by peripheral device.
            IMFa = cpu.IMFa,
            IMFb = cpu.IMFb,
        },
        
        mem = jit:fetch_memory_table(0, 65536)
        }
end



local function halt_65536_times()
    local t = {}
    local halt_instruction = 0x76
    for addr = 0, 65535 do
        t[addr] = halt_instruction
    end
    return t
end

local function run_code(initial_memory, code)
    -- make the JIT compiler and memory
    local jit = Z80JIT:new()
    jit:make_ROM(0,16384)
    jit:make_RAM(16384,16384)
    jit:load_memory(initial_memory, 0)
    jit:load_memory(code, 0)    -- load code at zero address
    
    -- now make a CPU to run the code
    local cpu = Z80CPU:new()
    local old_state = get_state(jit, cpu)

    local status
    repeat
        status = jit:run_z80(cpu, cpu.PC)
    until status ~= "ok"
    if status ~= "halt" then
        print("Failed to Halt")
        os.exit(1)
    end
    
    local new_state = get_state(jit, cpu)
    return old_state, new_state
end



local function assemble_code(code_in)
    local z = Z80_Assembler:new()
    z:set_compile_address(0)    -- compile for zero address

    code_in(z)
    
    local end_addr = z:get_compile_address()
    
    local code
    if not z:any_errors() then
        code = z:get_code()
    else
        print("FAIL: didn't assemble")
        for _,errors in ipairs(z:get_error_and_warning_messages()) do
            print(errors)
        end
        -- terminate immediately
        os.exit(1)
    end
    
    return code, end_addr
end

local function check_changes(old_state, new_state, checks)
    for k,v in pairs(checks) do
        if type(k) == "number" then
            -- address
            local new = (new_state.mem[k + 1]):byte()
            local old = (old_state.mem[k + 1]):byte()
            if new ~= v then
                print("Memory change didn't occur as expected")
                print("Address", k, "was", old, "now", new, "expected", v)
                os.exit(5)
            end
        else
            if new_state.reg[k] ~= v then
                print("Register change didn't occur as expected")
                print("Register", k, "was", old_state.reg[k], "now", new_state.reg[k], "expected", v)
                os.exit(4)
            end
            -- change it back so we can ignore it
            new_state.reg[k] = old_state.reg[k]
        end
    end
end

local function compare_state(old_state, new_state)
    for k,v in pairs(old_state.reg) do
        local new = new_state.reg[k]
        if new ~= v then
            print("Unexpected register change")
            print("Register", k, "was", v, "now", new)
            os.exit(2)
        end
    end
    for index, v in pairs(old_state.mem) do
        local new = new_state.mem[index]
        local addr = index - 1
        if v ~= new then
            print("Unexpected memory change")
            print("location: ", addr, "was", v:byte(),"now", new:byte())
            os.exit(3)
        end
    end
end


local function test(code, checks)
    local initial_mem = halt_65536_times()
    local binary, end_addr = assemble_code(code)
    if not checks.PC then
        checks.PC = end_addr + 1 -- +1 for halt instruction
    end
    local old_state, new_state = run_code(initial_mem, binary)

    check_changes(old_state, new_state, checks)
    compare_state(old_state, new_state)
end


local function run_batch(tests)
    local num_tests = #tests
    for i, one_test in pairs(tests) do
        print(string.format("Running test %i of %i - %s", i, num_tests, one_test[1]))
        test(one_test[2], one_test[3])
    end
    print("Finished all tests successfully")
end

--test("LD A, 33", { "A"=33, "F"={"C", "NZ"} )
--test("LD A, 33 \n LD(100),A", { [100]=33 }
-- test(function(z) z:LD("A", 33)   end, { ["A"]=33 })
--test(function(z) z:NOP()   end, { })
--test(function(z) z:assemble("LD", "BC", 0x4321) end, { B=0x43, C=0x21 })

local basic_instruction_tests = {
    
{ "NOP",     function(z) z:NOP()   end, { } },
{ "LD BC,n", function(z) z:assemble("LD", "BC", 0x4321) end, { B=0x43, C=0x21 } },
    
{ "LD   (BC),A", function(z)
                    z:assemble("LD", "BC", 0x8000) 
                    z:assemble("LD", "A", 0x01)
                    z:assemble("LD", "(BC)", "A") 
                end, 
                { B=0x80, C=0x00, A=0x01, [0x8001]=0x01 } },

--[[
    ["INC  BC"] =        0x03,
    ["INC  B"] =         0x04,
    ["DEC  B"] =         0x05,
    ["LD   B,!n!"] =     0x06,
    ["RLCA"] =           0x07,
    ["EX   AF,AF'"] =    0x08,
    ["ADD  HL,BC"] =     0x09,
    ["LD   A,(BC)"] =    0x0A,
    ["DEC  BC"] =        0x0b,
    ["INC  C"] =         0x0c,
    ["DEC  C"] =         0x0d,
    ["LD   C,!n!"] =     0x0e,
    ["RRCA"] =           0x0f,
    ["DJNZ !r!"] =       0x10,
    ["LD   DE,!nn!"] =   0x11,
    ["LD   (DE),A"] =    0x12,
    ["INC  DE"] =        0x13,
    ["INC  D"] =         0x14,
    ["DEC  D"] =         0x15,
    ["LD   D,!n!"] =     0x16,
    ["RLA"] =            0x17,
    ["JR   !r!"] =       0x18,
    ["ADD  HL,DE"] =     0x19,
    ["LD   A,(DE)"] =    0x1A,
    ["DEC  DE"] =        0x1B,
    ["INC  E"] =         0x1C,
    ["DEC  E"] =         0x1D,
    ["LD   E,!n!"] =     0x1E,
    ["RRA"] =            0x1F,
    ["JR   NZ,!r!"] =    0x20,
    ["LD   HL,!nn!"] =   0x21,
    ["LD   (!nn!),HL"] = 0x22,
    ["INC  HL"] =        0x23,
    ["INC  H"] =         0x24,
    ["DEC  H"] =         0x25,
    ["LD   H,!n!"] =     0x26,
    ["DAA"] =            0x27,
    ["JR   Z,!r!"] =     0x28,
    ["ADD  HL,HL"] =     0x29,
    ["LD   HL,(!nn!)"] = 0x2A,
    ["DEC  HL"] =        0x2B,
    ["INC  L"] =         0x2C,
    ["DEC  L"] =         0x2D,
    ["LD   L,!n!"] =     0x2E,
    ["CPL"] =            0x2F,
    ["JR   NC,!r!"] =    0x30,
    ["LD   SP,!nn!"] =   0x31,
    ["LD   (!nn!),A"] =  0x32,
    ["INC  SP"] =        0x33,
    ["INC  (HL)"] =      0x34,
    ["DEC  (HL)"] =      0x35,
    ["LD   (HL),!n!"] =  0x36,
    ["SCF"] =            0x37,
    ["JR   C,!r!"] =     0x38,
    ["ADD  HL,SP"] =     0x39,
    ["LD   A,(!nn!)"] =  0x3A,
    ["DEC  SP"] =        0x3B,
    ["INC  A"] =         0x3C,
    ["DEC  A"] =         0x3D,
--]]

{ "LD A,33", function(z) z:LD("A", 33)   end, { ["A"]=33 } },
--[[
    ["CCF"] =            0x3F,
    ["LD   B,B"] =       0x40,
    ["LD   B,C"] =       0x41,
    ["LD   B,D"] =       0x42,
    ["LD   B,E"] =       0x43,
    ["LD   B,H"] =       0x44,
    ["LD   B,L"] =       0x45,
    ["LD   B,(HL)"] =    0x46,
    ["LD   B,A"] =       0x47,
    ["LD   C,B"] =       0x48,
    ["LD   C,C"] =       0x49,
    ["LD   C,D"] =       0x4A,
    ["LD   C,E"] =       0x4B,
    ["LD   C,H"] =       0x4C,
    ["LD   C,L"] =       0x4D,
    ["LD   C,(HL)"] =    0x4E,
    ["LD   C,A"] =       0x4F,
    ["LD   D,B"] =       0x50,
    ["LD   D,C"] =       0x51,
    ["LD   D,D"] =       0x52,
    ["LD   D,E"] =       0x53,
    ["LD   D,H"] =       0x54,
    ["LD   D,L"] =       0x55,
    ["LD   D,(HL)"] =    0x56,
    ["LD   D,A"] =       0x57,
    ["LD   E,B"] =       0x58,
    ["LD   E,C"] =       0x59,
    ["LD   E,D"] =       0x5A,
    ["LD   E,E"] =       0x5B,
    ["LD   E,H"] =       0x5C,
    ["LD   E,L"] =       0x5D,
    ["LD   E,(HL)"] =    0x5E,
    ["LD   E,A"] =       0x5F,
    ["LD   H,B"] =       0x60,
    ["LD   H,C"] =       0x61,
    ["LD   H,D"] =       0x62,
    ["LD   H,E"] =       0x63,
    ["LD   H,H"] =       0x64,
    ["LD   H,L"] =       0x65,
    ["LD   H,(HL)"] =    0x66,
    ["LD   H,A"] =       0x67,
    ["LD   L,B"] =       0x68,
    ["LD   L,C"] =       0x69,
    ["LD   L,D"] =       0x6A,
    ["LD   L,E"] =       0x6B,
    ["LD   L,H"] =       0x6C,
    ["LD   L,L"] =       0x6D,
    ["LD   L,(HL)"] =    0x6E,
    ["LD   L,A"] =       0x6F,
    ["LD   (HL),B"] =    0x70,
    ["LD   (HL),C"] =    0x71,
    ["LD   (HL),D"] =    0x72,
    ["LD   (HL),E"] =    0x73,
    ["LD   (HL),H"] =    0x74,
    ["LD   (HL),L"] =    0x75,
    ["HALT"] =           0x76,
    ["LD   (HL),A"] =    0x77,
    ["LD   A,B"] =       0x78,
    ["LD   A,C"] =       0x79,
    ["LD   A,D"] =       0x7A,
    ["LD   A,E"] =       0x7B,
    ["LD   A,H"] =       0x7C,
    ["LD   A,L"] =       0x7D,
    ["LD   A,(HL)"] =    0x7E,
    ["LD   A,A"] =       0x7F,
    ["ADD  A,B"] =       0x80,
    ["ADD  A,C"] =       0x81,
    ["ADD  A,D"] =       0x82,
    ["ADD  A,E"] =       0x83,
    ["ADD  A,H"] =       0x84,
    ["ADD  A,L"] =       0x85,
    ["ADD  A,(HL)"] =    0x86,
    ["ADD  A,A"] =       0x87,
    ["ADC  A,B"] =       0x88,
    ["ADC  A,C"] =       0x89,
    ["ADC  A,D"] =       0x8A,
    ["ADC  A,E"] =       0x8B,
    ["ADC  A,H"] =       0x8C,
    ["ADC  A,L"] =       0x8D,
    ["ADC  A,(HL)"] =    0x8E,
    ["ADC  A,A"] =       0x8F,
    ["SUB  A,B"] =       0x90,
    ["SUB  A,C"] =       0x91,
    ["SUB  A,D"] =       0x92,
    ["SUB  A,E"] =       0x93,
    ["SUB  A,H"] =       0x94,
    ["SUB  A,L"] =       0x95,
    ["SUB  A,(HL)"] =    0x96,
    ["SUB  A,A"] =       0x97,
    ["SBC  A,B"] =       0x98,
    ["SBC  A,C"] =       0x99,
    ["SBC  A,D"] =       0x9A,
    ["SBC  A,E"] =       0x9B,
    ["SBC  A,H"] =       0x9C,
    ["SBC  A,L"] =       0x9D,
    ["SBC  A,(HL)"] =    0x9E,
    ["SBC  A,A"] =       0x9F,
    ["AND  B"] =         0xA0,
    ["AND  C"] =         0xA1,
    ["AND  D"] =         0xA2,
    ["AND  E"] =         0xA3,
    ["AND  H"] =         0xA4,
    ["AND  L"] =         0xA5,
    ["AND  (HL)"] =      0xA6,
    ["AND  A"] =         0xA7,
    ["XOR  B"] =         0xA8,
    ["XOR  C"] =         0xA9,
    ["XOR  D"] =         0xAA,
    ["XOR  E"] =         0xAB,
    ["XOR  H"] =         0xAC,
    ["XOR  L"] =         0xAD,
    ["XOR  (HL)"] =      0xAE,
    ["XOR  A"] =         0xAF,
    ["OR   B"] =         0xB0,
    ["OR   C"] =         0xB1,
    ["OR   D"] =         0xB2,
    ["OR   E"] =         0xB3,
    ["OR   H"] =         0xB4,
    ["OR   L"] =         0xB5,
    ["OR   (HL)"] =      0xB6,
    ["OR   A"] =         0xB7,
    ["CP   B"] =         0xB8,
    ["CP   C"] =         0xB9,
    ["CP   D"] =         0xBA,
    ["CP   E"] =         0xBB,
    ["CP   H"] =         0xBC,
    ["CP   L"] =         0xBD,
    ["CP   (HL)"] =      0xBE,
    ["CP   A"] =         0xBF,
    ["RET  NZ"] =        0xC0,
    ["POP  BC"] =        0xC1,
    ["JP   NZ,!nn!"] =   0xC2,
    ["JP   !nn!"] =      0xC3,
    ["CALL NZ,!nn!"] =   0xC4,
    ["PUSH BC"] =        0xC5,
    ["ADD  A,!n!"] =     0xC6,
    ["RST  00H"] =       0xC7,
    ["RET  Z"] =         0xC8,
    ["RET"] =            0xC9,
    ["JP   Z,!nn!"] =    0xCA,
    ["CALL Z,!nn!"] =    0xCC,
    ["CALL !nn!"] =      0xCD,
    ["ADC  A,!n!"] =     0xCE,
    ["RST  08H"] =       0xCF,
    ["RET  NC"] =        0xD0,
    ["POP  DE"] =        0xD1,
    ["JP   NC,!nn!"] =   0xD2,
    ["OUT  (!n!),A"] =   0xD3,
    ["CALL NC,!nn!"] =   0xD4,
    ["PUSH DE"] =        0xD5,
    ["SUB  A,!n!"] =     0xD6,
    ["RST  10H"] =       0xD7,
    ["RET  C"] =         0xD8,
    ["EXX"] =            0xD9,
    ["JP   C,!nn!"] =    0xDA,
    ["IN   A,(!n!)"] =   0xDB,
    ["CALL C,!nn!"] =    0xDC,
    ["SBC  A,!n!"] =     0xDE,
    ["RST  18H"] =       0xDF,
    ["RET  PO"] =        0xE0,
    ["POP  HL"] =        0xE1,
    ["JP   PO,!nn!"] =   0xE2,
    ["EX   (SP),HL"] =   0xE3,
    ["CALL PO,!nn!"] =   0xE4,
    ["PUSH HL"] =        0xE5,
    ["AND  !n!"] =       0xE6,
    ["RST  20H"] =       0xE7,
    ["RET  PE"] =        0xE8,
    ["JP   (HL)"] =      0xE9,
    ["JP   PE,!nn!"] =   0xEA,
    ["EX   DE,HL"] =     0xEB,
    ["CALL PE,!nn!"] =   0xEC,
    ["XOR  !n!"] =       0xEE,
    ["RST  28H"] =       0xEF,
    ["RET  P"] =         0xF0,
    ["POP  AF"] =        0xF1,
    ["JP   P,!nn!"] =    0xF2,
    ["DI"] =             0xF3,
    ["CALL P,!nn!"] =    0xF4,
    ["PUSH AF"] =        0xF5,
    ["OR   !n!"] =       0xF6,
    ["RST  30H"] =       0xF7,
    ["RET  M"] =         0xF8,
    ["LD   SP,HL"] =     0xF9,
    ["JP   M,!nn!"] =    0xFA,
    ["EI"] =             0xFB,
    ["CALL M,!nn!"] =    0xFC,
    ["CP   !n!"] =       0xFE,
    ["RST  38H"] =       0xFF,
--]]

}

run_batch(basic_instruction_tests)
--run_batch(CB_instruction_tests)
--run_batch(ED_instruction_tests)
--run_batch(DD_instruction_tests)
--run_batch(FD_instruction_tests)
--run_batch(DDCB_instruction_tests)
--run_batch(FDCB_instruction_tests)
--run_batch(memory_invalidation_tests)
--run_batch(more_advanced_tests)
