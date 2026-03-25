# Comprehensive Survey of Open-Source RISC-V Cores for FPGA (Xilinx 7-Series)

*Compiled 2026-03-25 for the KR RISC-V project*
*Focus: Custom bignum/arbitrary-precision instruction extensions, OOO execution, Pari/GP viability*

---

## Table of Contents

1. [Executive Summary & Recommendations](#executive-summary)
2. [Core-by-Core Analysis](#core-analysis)
3. [Summary Comparison Table](#comparison-table)
4. [Custom Instruction Extension Mechanisms](#custom-instructions)
5. [Out-of-Order Execution Options](#ooo-options)
6. [Pari/GP Feasibility Analysis](#parigp-feasibility)
7. [Sources](#sources)

---

## 1. Executive Summary & Recommendations <a name="executive-summary"></a>

### Top Picks for This Project

**For custom bignum instruction extensions on Xilinx 7-series:**

1. **VexRiscv** (BEST OVERALL) -- Mature plugin architecture makes adding custom instructions trivially clean. Proven extensively on Artix-7. Excellent FPGA efficiency. The CfuPlugin provides a structured path for custom ALU operations. LiteX ecosystem gives you a full SoC for free. MIT license.

2. **NEORV32** (BEST IF YOU PREFER VHDL) -- Purpose-built Custom Functions Unit (CFU/Xcfu) supporting up to 1024 custom instructions with direct register file access. Pure VHDL, zero dependencies, platform-independent. Excellent documentation. BSD-3-Clause license. Proven on all major FPGA families.

3. **CVA5/Taiga** (BEST FOR EXTENSIBLE APPLICATION-CLASS) -- Designed from the ground up for FPGA with modular execution units. Adding new functional units is a first-class design goal. SystemVerilog. Supports RV32IMAFD. Solderpad/Apache-2.0 license.

**For out-of-order execution research:**

4. **RSD** (BEST OOO FOR FPGA) -- Purpose-built FPGA-optimized OOO superscalar. 2.5x better DMIPS than BOOM on FPGA with fewer resources. SystemVerilog. Apache-2.0.

5. **BOOM** (MOST MATURE OOO) -- Industry-competitive OOO design via Chipyard. RV64GCB. Massive resource usage makes it impractical on Artix-7 but viable on Kintex-7/Virtex-7.

**For running Pari/GP or its core algorithms:**

Running full Pari/GP requires Linux (or at minimum a C runtime with malloc, stdio, etc.), which narrows the field to cores supporting MMU + Supervisor mode: **VexRiscv** (Linux-capable config), **Rocket**, **CVA6**, or **BOOM**. For a stripped-down bignum kernel, any core with custom instruction support suffices.

---

## 2. Core-by-Core Analysis <a name="core-analysis"></a>

---

### 2.1 VexRiscv

| Attribute | Details |
|---|---|
| **Source Language** | SpinalHDL (Scala-based, generates Verilog) |
| **ISA Support** | RV32I/M/A/F/D/C, configurable |
| **Pipeline Stages** | 2 to 5+ (configurable) |
| **License** | MIT |
| **Maturity** | Very High -- widely deployed, FPGA contest winner, production use |
| **SoC Ecosystem** | LiteX (full Linux SoC), Briey SoC, Murax SoC; Wishbone/AXI buses; JTAG debug; Linux/Zephyr/FreeRTOS |

**FPGA Resource Usage on Artix-7:**

| Configuration | Fmax | LUTs | FFs | Notes |
|---|---|---|---|---|
| Small (RV32I, no bypass) | 240 MHz | 556 | 566 | 0.52 DMIPS/MHz |
| Small & Productive (RV32I) | 232 MHz | 816 | 534 | 0.82 DMIPS/MHz |
| Full (RV32IM, 4KB caches) | 199 MHz | 1,840 | 1,158 | 1.21 DMIPS/MHz |
| Full Max Perf (RV32IM, 8KB caches) | 200 MHz | 1,935 | 1,216 | 1.38 DMIPS/MHz |
| Full + MMU (RV32IM) | 151 MHz | 2,021 | 1,541 | 1.24 DMIPS/MHz |
| Linux Balanced (RV32IMA, MMU) | 180 MHz | 2,883 | 2,130 | 1.21 DMIPS/MHz |
| Murax SoC (interlocked) | 216 MHz | 1,109 | -- | Tiny SoC |
| Briey SoC | 181 MHz | 3,220 | 3,181 | Full SoC w/ UART, GPIO, timers |

**Custom Instruction Support: EXCELLENT**
- Plugin architecture allows adding instructions without modifying core source
- CfuPlugin provides a standardized Custom Function Unit interface
- Custom instructions execute in the pipeline with direct register file access
- Example: SIMD_ADD plugin demonstrates the pattern; community has built crypto accelerators, ML accelerators, etc.
- Google's CFU Playground project specifically uses VexRiscv for ML custom instructions on FPGA
- Adding a bignum multiply-accumulate or wide-add instruction is straightforward

**Verdict:** The strongest overall candidate. Best FPGA efficiency, best plugin system for custom instructions, massive community, proven Linux support, and the LiteX ecosystem provides a complete development environment. The only downside is requiring Scala/SpinalHDL knowledge to modify the core (though generated Verilog can be used as-is).

---

### 2.2 VexiiRiscv (Successor to VexRiscv)

| Attribute | Details |
|---|---|
| **Source Language** | SpinalHDL (Scala-based) |
| **ISA Support** | RV32/RV64 IMAFDCSU |
| **Pipeline Stages** | Configurable, up to 6-stage dual-issue |
| **License** | MIT |
| **Maturity** | Medium -- under active development, not yet as battle-tested as VexRiscv |
| **SoC Ecosystem** | LiteX integration, AXI4/Wishbone/Tilelink buses, JTAG debug |

**Performance:** 2.50 DMIPS/MHz, 5.24 CoreMark/MHz (baremetal)

**Key Improvements Over VexRiscv:**
- RV64 support (critical if you want 64-bit addressing for large bignum operands)
- Dual-issue capable
- Non-blocking write-back caches (vs. write-through in VexRiscv)
- Better branch prediction (BTB/RAS/GShare)
- MMU with SV32/SV39
- Multi-core coherency support
- Cleaner architecture without VexRiscv's technical debt

**Custom Instruction Support: EXCELLENT**
- Same plugin architecture as VexRiscv, but improved
- Goal: scale from Cortex-M0 to Cortex-A53 class through configuration

**Verdict:** The future of SpinalHDL RISC-V cores. If you need RV64 (which may be important for Pari/GP's 64-bit word operations), VexiiRiscv is the path forward. Less mature than VexRiscv but rapidly improving.

---

### 2.3 PicoRV32

| Attribute | Details |
|---|---|
| **Source Language** | Verilog |
| **ISA Support** | RV32I/M/C/E (configurable) |
| **Pipeline Stages** | Non-pipelined (multicycle, ~4 CPI average) |
| **License** | ISC (MIT-equivalent) |
| **Maturity** | Very High -- by Clifford Wolf (YosysHQ), widely used |
| **SoC Ecosystem** | PicoSoC example; memory-mapped SPI flash; AXI4-lite interface |

**FPGA Resource Usage on Xilinx 7-Series:**

| Configuration | Fmax | LUTs | Notes |
|---|---|---|---|
| Small (no counters, no 2-stage shifts) | 250-450 MHz | ~750 | Minimal config |
| Regular (default) | 250-450 MHz | ~900 | Standard |
| Large (PCPI, IRQ, MUL, DIV, BARREL, COMPRESSED) | 250-450 MHz | ~2,000 | Full featured |

**Custom Instruction Support: GOOD (via PCPI)**
- Pico Co-Processor Interface (PCPI) allows external execution units
- Non-branching instructions can be offloaded to external hardware
- Built-in PCPI cores for MUL/DIV demonstrate the pattern
- Research projects have added custom MAC instructions via PCPI
- Clean, simple Verilog interface -- easy to understand and extend

**Verdict:** Optimized for size and Fmax, not raw performance. The ~4 CPI makes it slow for compute-heavy workloads like bignum math. PCPI interface is clean but limited (no direct pipeline integration). Best suited as a controller core rather than a compute core. The pure Verilog and simplicity are major advantages for teams that want something they can fully understand.

---

### 2.4 NEORV32

| Attribute | Details |
|---|---|
| **Source Language** | VHDL (platform-independent, zero dependencies) |
| **ISA Support** | RV32 I/E/M/A/C/B/U/X + Zicsr, Zicntr, Zifencei, Zfinx, Zba/Zbb/Zbs/Zbc, Zkn/Zks (crypto), Xcfu |
| **Pipeline Stages** | 2-stage (fetch + execute) |
| **License** | BSD-3-Clause |
| **Maturity** | Very High -- actively maintained, excellent documentation, used in education and industry |
| **SoC Ecosystem** | Complete MCU-class SoC: 2x UART, SPI, I2C, 1-Wire, GPIO, PWM, NEOLED, TRNG, DMA, timers; Wishbone bus (XBUS); AXI4-Stream (SLINK); JTAG debugger (OpenOCD/GDB); bootloader |

**FPGA Resource Usage (Cyclone IV reference, Xilinx comparable):**

| Configuration | Fmax | LUTs | FFs | Notes |
|---|---|---|---|---|
| rv32imc_Zicsr_Zicntr (RTOS-capable) | 130 MHz | ~2,300 | ~1,000 | Cyclone IV reference |
| Minimal rv32i | -- | ~1,000 | -- | Estimated core-only |

Tested on: AMD/Xilinx, Intel/Altera, Lattice, Microchip, Gowin, Cologne Chip, NanoXplore FPGAs.

**Custom Instruction Support: EXCELLENT (CFU/Xcfu)**
- Dedicated Custom Functions Unit (CFU) module: `neorv32_cpu_alu_cfu.vhd`
- Integrated directly into the CPU's ALU with direct register file access
- Up to 1024 custom instructions via funct7 (7 bits) + funct3 (3 bits) encoding
- Enabled by setting `RISCV_ISA_Xcfu` generic to `true`
- Software intrinsics provided in `neorv32_cpu_cfu.h`
- Demo program in `sw/example/demo_cfu/main.c`
- Pure VHDL -- no exotic toolchain needed, just standard synthesis tools
- Custom instructions can be multi-cycle with handshaking

**Verdict:** The best choice if you want VHDL and a self-contained MCU. The CFU is purpose-built for exactly the kind of custom instruction extension needed for bignum operations. The 2-stage pipeline keeps things simple. The comprehensive peripheral set means you get a complete system. Cannot run Linux (no MMU), but ideal for bare-metal bignum computation with custom hardware acceleration.

---

### 2.5 Rocket Core

| Attribute | Details |
|---|---|
| **Source Language** | Chisel (Scala-based, generates Verilog) |
| **ISA Support** | RV64GC (RV64IMAFDC), configurable |
| **Pipeline Stages** | 5-stage in-order |
| **License** | BSD-3-Clause + Apache-2.0 (SiFive components) |
| **Maturity** | Very High -- Berkeley reference implementation, basis for SiFive commercial cores |
| **SoC Ecosystem** | Chipyard framework; TileLink interconnect; JTAG debug; Linux-capable; AXI bridges |

**FPGA Resource Usage on Xilinx:**

| Configuration | LUTs | Notes |
|---|---|---|
| RocketTile (core only) | ~4,400 | Minimal RV64 core |
| Full SoC (with TileLink, AXI) | ~11,200 | Minimal SoC |
| With FPU, caches, etc. | 15,000-25,000+ | Typical Linux-capable |

Fmax on Xilinx 7-series: typically 50-100 MHz depending on configuration.

**Custom Instruction Support: EXCELLENT (RoCC)**
- Rocket Custom Coprocessor (RoCC) interface is a first-class feature
- RoCC accelerators get: direct register file access, L1 cache access, page table walker access
- custom0-custom3 opcodes supported by the toolchain out of the box
- Well-documented: Chipyard has full tutorials, CS250 Berkeley has SHA3 example
- Mature ecosystem of example accelerators (crypto, ML, etc.)
- Chisel-based design makes accelerator development productive

**Verdict:** The "official" RISC-V reference implementation. RoCC is the gold standard for custom accelerator interfaces. RV64 support is important for 64-bit bignum word operations. However: Chisel build system is complex, FPGA resource usage is high, and Fmax on 7-series is modest. Best if you already know the Chipyard ecosystem or need RV64 with Linux.

---

### 2.6 BOOM (Berkeley Out-of-Order Machine)

| Attribute | Details |
|---|---|
| **Source Language** | Chisel (Scala-based) |
| **ISA Support** | RV64GCB |
| **Pipeline Stages** | 7 effective stages (10 logical): Fetch, Decode/Rename, Rename/Dispatch, Issue/RegRead, Execute, Memory, Writeback |
| **License** | BSD-3-Clause + Apache-2.0 |
| **Maturity** | High -- academic reference for OOO RISC-V, used in FireSim |
| **SoC Ecosystem** | Chipyard (required); TileLink; same ecosystem as Rocket |

**Out-of-Order Details:**
- Superscalar (2-wide fetch, configurable issue width)
- Register renaming with physical register file
- Reorder buffer (ROB, configurable 32-64+ entries)
- Speculative execution with branch prediction
- Out-of-order memory execution with disambiguation
- 6.2 CoreMark/MHz (SonicBOOM/v3)

**FPGA Resource Usage:**
- 2-wide/3-issue config: ~50% of LUTs on a ZC7020 (~26,000 LUTs used)
- Fmax on FPGA: 90+ MHz (via FireSim on AWS F1)
- Will NOT fit on smaller Artix-7 devices (35T/100T)
- Requires Kintex-7 325T or larger for practical deployment

**Custom Instruction Support: VIA RoCC**
- Same RoCC interface as Rocket (shared Chipyard ecosystem)
- Custom accelerators attach through the same mechanism

**Verdict:** The only truly mature open-source OOO RISC-V core. Relevant for studying OOO scheduling for your project, but impractical to run on typical Artix-7 boards due to resource consumption. If you have a Kintex-7 or Virtex-7 board, BOOM is viable for research. The OOO scheduling logic itself could be studied and adapted for your custom bignum scheduler design.

---

### 2.7 Ibex (lowRISC)

| Attribute | Details |
|---|---|
| **Source Language** | SystemVerilog |
| **ISA Support** | RV32I/E/M/C/B (Zba, Zbb, Zbc, Zbs) + Zicsr |
| **Pipeline Stages** | 2-stage (small config) or 3-stage (maxperf config) |
| **License** | Apache-2.0 |
| **Maturity** | Very High -- production quality, powers OpenTitan silicon |
| **SoC Ecosystem** | OpenTitan SoC; Ibex Demo System (Arty A7); PULP debug; OpenOCD/GDB |

**FPGA Resource Usage on Xilinx 7-Series:**

| Configuration | LUTs | Notes |
|---|---|---|
| Small (2-stage) | ~2,500 | 50 MHz target, 1 DSP |
| Ibex Demo System on Arty A7 | ~3,500 | 2.6% of XC7A100T |

ASIC gate estimates: 15-61 kGE depending on configuration.

**Custom Instruction Support: LIMITED**
- No built-in custom instruction interface in the mainline core
- ETH Zurich has a research extension interface (not upstream)
- RISQ-V project demonstrated tightly-coupled accelerators for post-quantum crypto
- Adding custom instructions requires modifying the core RTL directly
- Not designed for easy extensibility in this regard

**Verdict:** Excellent production-quality core, but primarily designed as an ASIC-first secure embedded controller (OpenTitan). FPGA is a secondary target -- higher resource usage and lower Fmax compared to FPGA-native designs like VexRiscv. Custom instruction support is weak compared to VexRiscv or NEORV32. Not recommended for this project unless you specifically need OpenTitan compatibility.

---

### 2.8 CVA6 / Ariane

| Attribute | Details |
|---|---|
| **Source Language** | SystemVerilog |
| **ISA Support** | RV32/RV64 IMAC, Supervisor mode, MMU (SV32/SV39) |
| **Pipeline Stages** | 6-stage, single-issue, in-order (with out-of-order writeback) |
| **License** | Solderpad-0.51 / BSD-3-Clause / Apache-2.0 |
| **Maturity** | High -- OpenHW Group maintained, multiple tape-outs |
| **SoC Ecosystem** | OpenHW Group ecosystem; AXI4 bus; JTAG debug; Linux-capable; Zephyr support |

**FPGA Resource Usage:**
- Target: Genesys 2 (Kintex-7 XC7K325T) at 50-100 MHz
- Full RV64 config with caches: estimated 20,000-30,000 LUTs
- RV32 configs with posit extensions: ~15,743 LUTs + 4,057 FFs (research paper)
- Too large for Artix-7 35T; fits on Artix-7 100T (tight) or Kintex-7

**Partial Out-of-Order:** Execution stage allows out-of-order writeback, but issue and commit are in-order.

**Custom Instruction Support: GOOD (CV-X-IF)**
- CORE-V eXtension InterFace (CV-X-IF) for coprocessor integration
- Coprocessor operates as another functional unit in the execute stage
- Currently implements 3 mandatory interfaces: issue, commit, result
- Compressed, memory, and memory result interfaces not yet implemented
- Used in research for crypto accelerators, posit arithmetic, CGRA integration

**Verdict:** A capable Linux-class core with a standardized extension interface. The CV-X-IF is well-designed but still maturing (missing some interfaces). Better suited for Kintex-7 than Artix-7 due to size. Good choice if you need RV64 + Linux + custom extensions in a single core that isn't as complex as Rocket/BOOM.

---

### 2.9 SERV

| Attribute | Details |
|---|---|
| **Source Language** | Verilog |
| **ISA Support** | RV32I + optional M, C, Zicsr |
| **Pipeline Stages** | Bit-serial (processes 1 bit per cycle -- no traditional pipeline) |
| **License** | ISC |
| **Maturity** | High -- world record 6,000 cores on single FPGA |
| **SoC Ecosystem** | Servant SoC; FuseSoC-based build system |

**FPGA Resource Usage:**

| FPGA | LUTs | FFs |
|---|---|---|
| AMD Artix-7 | 125 | 164 |
| Lattice iCE40 | 198 | 164 |
| Intel Cyclone 10LP | 239 | 164 |

**Custom Instruction Support: MINIMAL**
- No custom instruction framework
- Bit-serial architecture makes custom wide operations impractical
- Adding a 256-bit multiply would take 256+ cycles minimum through the serial datapath

**Verdict:** Remarkable engineering achievement but fundamentally wrong for bignum computation. The bit-serial architecture means a 32-bit multiply takes 32+ cycles. Custom wide-word operations would be painfully slow. Useful only if you need many tiny cores (e.g., for embarrassingly parallel problems). Not suitable for this project.

---

### 2.10 Minerva

| Attribute | Details |
|---|---|
| **Source Language** | Amaranth HDL (Python-based, generates Verilog) |
| **ISA Support** | RV32IM + Zicsr |
| **Pipeline Stages** | 6-stage (Address, Fetch, Decode, Execute, Memory, Writeback) |
| **License** | BSD-2-Clause |
| **Maturity** | Low-Medium -- niche community, limited development activity |
| **SoC Ecosystem** | LiteX integration; optional I$/D$ caches |

**FPGA Resource Usage:** Not publicly documented with specific numbers. Estimated ~1,500-2,500 LUTs based on similar 6-stage RV32IM cores.

**Custom Instruction Support: NONE**
- No custom instruction interface
- Would require modifying the Python HDL source

**Verdict:** Interesting if you're already in the Amaranth/Python HDL ecosystem, but limited community, no custom instruction support, and sparse documentation make it a poor choice for this project.

---

### 2.11 SweRV / VeeR (Western Digital)

| Attribute | Details |
|---|---|
| **Source Language** | SystemVerilog |
| **Variants** | EH1 (2-way superscalar, 9-stage), EH2 (2-way superscalar + 2-way SMT), EL2 (scalar, 4-stage) |
| **ISA Support** | RV32IMC + Zicsr, Zba/Zbb/Zbs (EL2) |
| **License** | Apache-2.0 |
| **Maturity** | High -- production use at Western Digital for SSD controllers |
| **SoC Ecosystem** | VeeRwolf SoC (FuseSoC-based); AXI4 interconnect; UART, SPI, GPIO, timer; Nexys A7 support |

**FPGA Resource Usage:**

| Variant | Artix-7 Fit? | Estimated LUTs | Fmax | Notes |
|---|---|---|---|---|
| EL2 (scalar, 4-stage) | Yes (100T) | ~8,000-12,000 | 50-80 MHz | Reasonable fit |
| EH1 (superscalar, 9-stage) | Tight (100T) | ~30,000-40,000 | ~40 MHz | Fills ~50% of large Artix-7 |
| EH2 (superscalar + SMT) | No (need Kintex) | >40,000 | -- | Too large for Artix-7 |

EH1 achieves 4.9 CoreMark/MHz; EH2 achieves 6.3 CoreMark/MHz.

**Custom Instruction Support: LIMITED**
- No formal custom instruction interface
- ASIC-first design not optimized for FPGA extensibility
- Register file uses 4R/2W ports requiring flip-flops (wasteful on FPGA)
- Critical path in decoder limits Fmax on FPGA

**Verdict:** Impressive ASIC-oriented cores, but poor FPGA citizens. The superscalar EH1/EH2 are too large and too slow on FPGA to be practical. The EL2 is more reasonable but still lacks custom instruction support. Not recommended for this project.

---

### 2.12 Hazard3

| Attribute | Details |
|---|---|
| **Source Language** | Verilog (SystemVerilog) |
| **ISA Support** | RV32I/E/M/A/C + Zba, Zbb, Zbc, Zbs, Zbkb, Zbkx, Zcb, Zcmp, Zicsr, PMP |
| **Pipeline Stages** | 3-stage |
| **License** | Apache-2.0 |
| **Maturity** | High -- production silicon in RP2350 (Raspberry Pi Pico 2) |
| **SoC Ecosystem** | Example SoC with 128KB RAM, UART, timer, JTAG debug; targets iCEBreaker, ULX3S, Arty A7-100T |

**Performance:** 4.15 CoreMark/MHz (RP2350 config); 4.25 with Zbc.

**FPGA Resource Usage:** Not officially published, but estimated ~1,500-2,500 LUTs for the core based on 3-stage RV32IMC complexity. Proven on iCEBreaker (iCE40 UP5K, 5,280 LUTs) and Arty A7-100T.

**Custom Instruction Support: MODERATE**
- Source is open and designed to be modifiable
- Raspberry Pi explicitly encourages students to add custom instructions and test on FPGA
- No formal plugin system like VexRiscv, but clean 3-stage pipeline is easy to extend
- RP2350 silicon implements custom Hazard3 extensions beyond standard RISC-V

**Verdict:** A polished, production-proven core with excellent bit manipulation support (relevant for bignum carry propagation). The 3-stage pipeline is simple enough to modify for custom instructions, though it lacks VexRiscv's plugin elegance. Good candidate if you want clean Verilog you can understand and modify directly. The Arty A7 support is a plus.

---

### 2.13 FemtoRV

| Attribute | Details |
|---|---|
| **Source Language** | Verilog |
| **ISA Support** | RV32I (quark) up to RV32IMFC (petitbateau) |
| **Pipeline Stages** | Multi-cycle, non-pipelined (2-3 cycles/instruction typical) |
| **License** | BSD |
| **Maturity** | Medium -- educational project, well-documented tutorials |
| **SoC Ecosystem** | Minimal SoC with UART, LEDs; FemtoSOC |

**FPGA Resource Usage:**
- Quark (RV32I minimal): ~400 LUTs
- Standard config: ~1,000 LUTs
- Fits on Lattice IceStick (<1,280 LUTs)

**Custom Instruction Support: MINIMAL**
- Educational design -- clean code but no formal extension mechanism
- 400-1000 lines of Verilog makes it easy to understand and modify

**Verdict:** Excellent for learning RISC-V internals, but not suitable for production use or compute-intensive workloads. The multi-cycle design and minimal ISA support make it impractical for bignum computation. The code quality and tutorials are outstanding for educational purposes.

---

### 2.14 DarkRISCV

| Attribute | Details |
|---|---|
| **Source Language** | Verilog |
| **ISA Support** | RV32I/E + optional MAC custom instruction |
| **Pipeline Stages** | 2-stage (dual-clock) or 3-stage (single-clock) |
| **License** | BSD |
| **Maturity** | Medium -- hobby/experimental project, broadly tested |
| **SoC Ecosystem** | DarkSoCV (ROM, RAM, I/O); DarkUART; DarkBridge; optional caches; optional SDRAM controller |

**FPGA Resource Usage on Xilinx:**

| Device | Fmax | LUTs | Notes |
|---|---|---|---|
| Artix-7 speed grade 2 | 178 MHz | 850-1,500 | Core only |
| Kintex-7 speed grade 2 | 225 MHz | ~1,000 | Core only |
| Kintex-7 speed grade 3 | 266 MHz | ~1,000 | Core only |
| Spartan-6 | 100 MHz | ~1,000 | Core only |

**Custom Instruction Support: BASIC**
- Has a custom MAC instruction using opcode 7'b0001011
- Demonstrates that custom instructions are possible
- No formal extension framework

**Verdict:** Impressively small and fast for what it is, with proven Xilinx 7-series results. The existing custom MAC instruction shows the path for adding bignum operations. However, the experimental nature and minimal ISA support (no M extension standard) limit its utility. The code is harder to read than FemtoRV or PicoRV32.

---

### 2.15 CVA5 / Taiga

| Attribute | Details |
|---|---|
| **Source Language** | SystemVerilog |
| **ISA Support** | RV32IMAFD |
| **Pipeline Stages** | 5-stage with parallel variable-latency execution units |
| **License** | Solderpad-2.1 / Apache-2.0 |
| **Maturity** | Medium -- OpenHW Group project, derived from Taiga (SFU) |
| **SoC Ecosystem** | Nexys A7 example; Vivado integration; AXI bus |

**Custom Instruction Support: EXCELLENT**
- Designed from the ground up with modular, parallel execution units
- Adding new functional units is a first-class architectural goal
- Standardized execution unit interface with variable latency support
- SCAIE-V framework extended to support CVA5 custom instructions
- Only single-digit percentage area overhead for custom instruction units
- Minimal frequency impact even for complex custom instructions

**Verdict:** A hidden gem for this project. The architecture was specifically designed for heterogeneous computing with custom execution units. The parallel, variable-latency execution unit design is ideal for a multi-cycle bignum multiply unit. SystemVerilog is more accessible than SpinalHDL. Less community than VexRiscv but a cleaner extensibility model for complex functional units.

---

### 2.16 RSD (RISC-V Out-of-Order Superscalar)

| Attribute | Details |
|---|---|
| **Source Language** | SystemVerilog |
| **ISA Support** | RV32IMF |
| **Pipeline Stages** | OOO: 2-fetch front-end, 6-issue back-end |
| **License** | Apache-2.0 |
| **Maturity** | Medium -- academic (University of Tokyo), published at FPT'19 |
| **SoC Ecosystem** | Targets Xilinx Zynq (ZedBoard); Vivado/Synplify synthesis |

**Out-of-Order Features:**
- 2-wide fetch, 6-wide issue
- Up to 64 in-flight instructions (configurable)
- Speculative scheduling with replay
- OOO load/store with dynamic disambiguation
- Memory dependence predictor
- Non-blocking L1 data cache
- FPGA-optimized multiport RAM implementations

**FPGA Resource Usage:**
- 2.5x better DMIPS than BOOM with fewer FPGA resources
- Specifically optimized for FPGA (vs. BOOM which is ASIC-first)
- Targets Zynq XC7Z020 (~53,000 LUTs available)

**Custom Instruction Support: NOT DOCUMENTED**
- No formal custom instruction interface documented
- Would require modifying SystemVerilog source

**Verdict:** The best open-source OOO core for FPGA study. If your project goal includes building or studying an OOO scheduler for bignum operations, RSD's FPGA-optimized OOO microarchitecture is the most relevant reference design. The speculative scheduling and replay mechanism are directly applicable to designing an OOO bignum instruction scheduler.

---

## 3. Summary Comparison Table <a name="comparison-table"></a>

| Core | Language | ISA | Pipeline | Artix-7 LUTs | Artix-7 Fmax | Custom Insn | OOO | Linux | License |
|---|---|---|---|---|---|---|---|---|---|
| **VexRiscv** | SpinalHDL | RV32IMAFDC | 2-5 stage | 556-2,883 | 180-240 MHz | **Excellent** (Plugin) | No | Yes (w/MMU) | MIT |
| **VexiiRiscv** | SpinalHDL | RV32/64IMAFDC | up to 6-stage | TBD | TBD | **Excellent** (Plugin) | No | Yes | MIT |
| **PicoRV32** | Verilog | RV32IMC/E | Multi-cycle | 750-2,000 | 250-450 MHz | Good (PCPI) | No | No | ISC |
| **NEORV32** | VHDL | RV32IMACBU+crypto | 2-stage | ~2,000-2,500 | ~120-130 MHz | **Excellent** (CFU) | No | No | BSD-3 |
| **Rocket** | Chisel | RV64GC | 5-stage | 4,400-25,000+ | 50-100 MHz | **Excellent** (RoCC) | No | Yes | BSD-3/Apache |
| **BOOM** | Chisel | RV64GCB | 7-stage OOO | ~26,000-50,000 | ~90 MHz | Good (RoCC) | **Yes** | Yes | BSD-3/Apache |
| **Ibex** | SystemVerilog | RV32IMC/B | 2-3 stage | 2,500-3,500 | ~50 MHz | Limited | No | No | Apache-2.0 |
| **CVA6** | SystemVerilog | RV32/64IMAC | 6-stage | 15,000-30,000 | 50-100 MHz | Good (CV-X-IF) | Partial | Yes | Solderpad/BSD/Apache |
| **SERV** | Verilog | RV32IMC | Bit-serial | **125** | -- | None | No | No | ISC |
| **Minerva** | Amaranth | RV32IM | 6-stage | ~1,500-2,500 | -- | None | No | No | BSD-2 |
| **SweRV EH1** | SystemVerilog | RV32IMC | 9-stage 2-way | ~30,000-40,000 | ~40 MHz | Limited | No | No | Apache-2.0 |
| **SweRV EL2** | SystemVerilog | RV32IMC+Zb | 4-stage | ~8,000-12,000 | 50-80 MHz | Limited | No | No | Apache-2.0 |
| **Hazard3** | Verilog | RV32IMAC+Zb | 3-stage | ~1,500-2,500 | -- | Moderate | No | No | Apache-2.0 |
| **FemtoRV** | Verilog | RV32I-IMFC | Multi-cycle | 400-1,000 | -- | Minimal | No | No | BSD |
| **DarkRISCV** | Verilog | RV32I/E | 2-3 stage | 850-1,500 | 178-266 MHz | Basic | No | No | BSD |
| **CVA5/Taiga** | SystemVerilog | RV32IMAFD | 5-stage | ~5,000-10,000 | -- | **Excellent** | No | Yes (w/A) | Solderpad/Apache |
| **RSD** | SystemVerilog | RV32IMF | OOO 2F/6I | ~20,000-30,000 | -- | None | **Yes** | No | Apache-2.0 |

---

## 4. Custom Instruction Extension Mechanisms <a name="custom-instructions"></a>

This section ranks the cores by suitability for adding bignum/arbitrary-precision math instructions.

### Tier 1: Purpose-Built Extension Frameworks

| Core | Mechanism | Interface | Multi-Cycle? | Reg File Access | Toolchain Support |
|---|---|---|---|---|---|
| **VexRiscv** | Plugin system (CfuPlugin) | Scala plugin class | Yes | Direct | GCC custom0-3 |
| **NEORV32** | CFU (Xcfu extension) | VHDL module, ALU-integrated | Yes (handshake) | Direct | Intrinsics provided |
| **Rocket** | RoCC interface | Chisel LazyRoCC | Yes | Direct + L1$ + PTW | GCC custom0-3 |
| **CVA5/Taiga** | Execution unit interface | SystemVerilog module | Yes (variable latency) | Via issue logic | Standard RISC-V |
| **CVA6** | CV-X-IF | SystemVerilog interface | Yes | Via execute stage | Standard RISC-V |

### Tier 2: Coprocessor Interfaces

| Core | Mechanism | Notes |
|---|---|---|
| **PicoRV32** | PCPI | External coprocessor, non-branching only |
| **Hazard3** | Source modification | Clean pipeline, designed to be modified |
| **DarkRISCV** | Ad-hoc custom opcode | Has working example (MAC instruction) |

### Tier 3: Requires Core Modification

| Core | Difficulty |
|---|---|
| **Ibex** | Moderate -- SystemVerilog, well-structured but no plugin system |
| **BOOM** | Hard -- complex OOO pipeline, use RoCC instead |
| **Minerva** | Moderate -- Python HDL, no framework |
| **FemtoRV** | Easy -- very simple code, but limited infrastructure |
| **SERV** | Impractical -- bit-serial architecture incompatible with wide operations |
| **SweRV** | Hard -- complex superscalar design, ASIC-oriented |

### For Bignum/Arbitrary-Precision Specifically:

The ideal custom instruction for bignum math would be a **wide multiply-accumulate** (e.g., `MULACCW rd, rs1, rs2` that computes `rd = rs1 * rs2 + carry` producing a double-width result) or a **add-with-carry** instruction. Key requirements:

1. **Multi-cycle execution** -- a 32x32->64 multiply with accumulate needs 1-3 cycles in hardware
2. **Double-width result** -- need to write both result and carry/overflow
3. **Direct register access** -- avoiding memory round-trips for operands
4. **Low-latency integration** -- tightly coupled to avoid pipeline bubbles

**VexRiscv**, **NEORV32**, and **CVA5** all support these requirements natively through their extension frameworks. **Rocket's RoCC** also supports this but with higher latency due to the coprocessor interface.

Note: RISC-V has no carry flag by design (to simplify OOO execution), so multi-precision addition requires software carry propagation or a custom add-with-carry instruction.

---

## 5. Out-of-Order Execution Options <a name="ooo-options"></a>

| Core | OOO Type | Issue Width | ROB Size | FPGA-Optimized? | Xilinx 7-Series Viable? |
|---|---|---|---|---|---|
| **BOOM** | Full OOO superscalar | 2-4 wide | 32-64+ entries | No (ASIC-first) | Kintex-7 only (too large for Artix-7) |
| **RSD** | Full OOO superscalar | 2-fetch/6-issue | Up to 64 in-flight | **Yes** | Zynq Z-7020 (fits) |
| **CVA6** | Partial (OOO writeback) | Single-issue | N/A | Moderate | Kintex-7 recommended |
| **SweRV EH1** | In-order superscalar | 2-way | N/A | No | Barely fits Artix-7 100T |

**For studying OOO scheduling for your custom bignum scheduler:**

- **RSD** is the most relevant -- its FPGA-optimized OOO implementation demonstrates how to build speculative scheduling, replay mechanisms, and memory disambiguation efficiently on FPGA fabric
- **BOOM** is the most feature-complete OOO reference but its ASIC-centric design makes FPGA implementation challenging
- You could combine an in-order core (VexRiscv/NEORV32) with a custom OOO scheduler specifically for bignum instruction sequences, rather than using a general-purpose OOO core

---

## 6. Pari/GP Feasibility Analysis <a name="parigp-feasibility"></a>

### Running Full Pari/GP

Pari/GP requires:
- **64-bit integers preferred** (significand can be millions of digits; 64-bit word size doubles throughput)
- **Linux or POSIX-like OS** (stdio, malloc, dynamic memory)
- **GMP library** (GNU Multiple Precision) for underlying bignum operations
- **Substantial RAM** (megabytes minimum for large computations)

**Cores that can run full Pari/GP:**
1. **VexRiscv** (RV32IMA + MMU config) -- runs Linux, but 32-bit limits bignum word throughput
2. **VexiiRiscv** (RV64) -- best option if it matures; 64-bit Linux with custom instructions
3. **Rocket** (RV64GC) -- proven Linux, but high resource usage on FPGA
4. **CVA6** (RV64IMAC) -- Linux-capable, proven on Kintex-7
5. **BOOM** (RV64GCB) -- Linux-capable but massive resource usage

Pari/GP v2.17.0 has been confirmed running on RV64 Linux.

### Running Stripped-Down Bignum Kernels

For bare-metal execution of core bignum algorithms (no OS, no stdio, just compute):
- Any core with custom instruction support works
- **NEORV32 + CFU** is ideal: pure VHDL, direct ALU integration, bare-metal focus
- **VexRiscv + CfuPlugin** also excellent: more ecosystem support

### Recommended Architecture for This Project

Consider a heterogeneous approach:
1. **Control core**: VexRiscv (Linux-capable config) or NEORV32 for I/O, scheduling, and orchestration
2. **Compute accelerator**: Custom bignum execution unit attached via the core's extension interface (CfuPlugin or CFU)
3. **Optional OOO scheduler**: Study RSD's scheduling logic, implement a specialized OOO scheduler for bignum instruction streams

This separates the concerns of "running Pari/GP algorithms" from "accelerating bignum primitives" and lets you use the right tool for each.

---

## 7. Sources <a name="sources"></a>

### Core Repositories
- [VexRiscv - GitHub](https://github.com/SpinalHDL/VexRiscv)
- [VexiiRiscv - GitHub](https://github.com/SpinalHDL/VexiiRiscv)
- [VexiiRiscv Documentation](https://spinalhdl.github.io/VexiiRiscv-RTD/master/VexiiRiscv/Introduction/index.html)
- [PicoRV32 - GitHub](https://github.com/YosysHQ/picorv32)
- [NEORV32 - GitHub](https://github.com/stnolting/neorv32)
- [NEORV32 Datasheet](https://stnolting.github.io/neorv32/)
- [NEORV32 FPGA Setups](https://github.com/stnolting/neorv32-setups)
- [Rocket Chip - GitHub](https://github.com/chipsalliance/rocket-chip)
- [Chipyard Documentation (Rocket)](https://chipyard.readthedocs.io/en/latest/Generators/Rocket.html)
- [BOOM - GitHub](https://github.com/riscv-boom/riscv-boom)
- [BOOM Documentation](https://docs.boom-core.org/en/latest/sections/intro-overview/boom.html)
- [Ibex - GitHub](https://github.com/lowRISC/ibex)
- [Ibex Documentation](https://ibex-core.readthedocs.io/)
- [CVA6 - GitHub](https://github.com/openhwgroup/cva6)
- [CVA6 User Manual](https://docs.openhwgroup.org/projects/cva6-user-manual/)
- [CVA6 CV-X-IF Documentation](https://docs.openhwgroup.org/projects/cva6-user-manual/01_cva6_user/CVX_Interface_Coprocessor.html)
- [SERV - GitHub](https://github.com/olofk/serv)
- [Minerva - GitHub](https://github.com/minerva-cpu/minerva)
- [VeeRwolf (SweRV) - GitHub](https://github.com/chipsalliance/VeeRwolf)
- [SweRV EH1 FPGA - GitHub](https://github.com/westerndigitalcorporation/swerv_eh1_fpga)
- [Hazard3 - GitHub](https://github.com/Wren6991/Hazard3)
- [FemtoRV / learn-fpga - GitHub](https://github.com/BrunoLevy/learn-fpga)
- [DarkRISCV - GitHub](https://github.com/darklife/darkriscv)
- [CVA5 - GitHub](https://github.com/openhwgroup/cva5)
- [RSD - GitHub](https://github.com/rsd-devel/rsd)

### Reference Materials
- [Chipyard RoCC Accelerator Tutorial](https://chipyard.readthedocs.io/en/stable/Customization/RoCC-Accelerators.html)
- [SweRV Annotated Deep Dive - Tom Verbeure](https://tomverbeure.github.io/2019/03/13/SweRV.html)
- [NEORV32 CFU Custom Instructions Issue](https://github.com/stnolting/neorv32/issues/1490)
- [VexRiscv Custom Plugin Example](https://github.com/ThorKn/vexriscv-ulx3s-simple-plugin)
- [Xvpfloat: Variable Precision RISC-V Extension (CEA)](https://cea.hal.science/cea-04546949/file/VRP_journal_accepted_before_edition.pdf)
- [RSD: FPGA-Optimized OOO Processor Paper](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Mashimo-FPT'19.pdf)
- [CORE-V Extension Interface Spec](https://docs.openhwgroup.org/projects/openhw-group-core-v-xif/en/latest/intro.html)
- [RISC-V Custom Instruction Tutorial](https://pcotret.gitlab.io/riscv-custom/)
- [Taiga Processor Paper (CARRV 2017)](https://carrv.github.io/2017/papers/matthews-taiga-carrv2017.pdf)
- [Pari/GP on RISC-V](https://forums.raspberrypi.com/viewtopic.php?t=379692)
- [VexRiscv on Arty A7 (Antmicro)](https://antmicro.com/blog/2020/05/multicore-vex-in-litex)
- [Ibex Tightly-Coupled Accelerators (ETH Project)](https://iis-projects.ee.ethz.ch/index.php?title=Ibex:_Tightly-Coupled_Accelerators_and_ISA_Extensions)
- [SERV CoreScore Record](https://www.tomshardware.com/news/6000-risc-v-cores-on-a-xilinx-fpga-break-the-corescore-world-record)
- [Vivado RISC-V (Rocket on Xilinx)](https://github.com/eugene-tarassov/vivado-risc-v)
