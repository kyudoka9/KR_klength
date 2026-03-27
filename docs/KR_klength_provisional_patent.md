# PROVISIONAL PATENT APPLICATION

## VARIABLE-LENGTH NATIVE ARITHMETIC PROCESSING ARCHITECTURE WITH OUT-OF-ORDER MICRO-OPERATION SCHEDULING

Inventor: H. Ismail

Filing Date: March 25, 2026

Applicant: Kyudoka Research


## FIELD OF THE INVENTION

This invention relates to digital computing architectures for arbitrary-precision arithmetic, and more particularly to a hardware architecture that accepts multi-precision arithmetic instructions with runtime-variable operand lengths, decomposes them into word-level micro-operations with explicit dependency tracking, and schedules those micro-operations across heterogeneous compute resources using an out-of-order execution engine.


## CROSS-REFERENCE TO RELATED APPLICATIONS

Not applicable.


## BACKGROUND OF THE INVENTION

### The Fixed-Width Limitation

Conventional processor architectures operate on fixed-width data: 32-bit or 64-bit registers and arithmetic logic units (ALUs). When computations require operands exceeding the native word width, the processor must decompose the operation into sequences of word-level instructions managed entirely in software. For example, multiplying two 1024-bit integers on a 64-bit processor requires the software to issue approximately 256 individual multiply-accumulate instructions, manage carry propagation between each pair of words, and coordinate the accumulation of partial products into the final result.

This decomposition is performed by software libraries such as GMP (GNU Multiple Precision Arithmetic Library), Pari/GP, and FLINT. The processor hardware has no awareness that the sequence of individual word-level operations constitutes a single logical multi-precision operation.

### Limitations of Existing Approaches

Several categories of existing hardware fail to address the variable-length arithmetic problem:

**Fixed-width cryptographic accelerators.** Hardware accelerators for RSA, elliptic curve cryptography (ECC), and lattice-based cryptography operate on predetermined operand widths (e.g., 256-bit for ECC, 2048-bit or 4096-bit for RSA). They cannot process operands of arbitrary length, limiting their applicability to specific cryptographic parameter sets. A change in the cryptographic standard or a research workload requiring non-standard operand sizes renders these accelerators inapplicable.

**GPU-based multi-precision arithmetic.** Graphics processing units (GPUs) provide large numbers of parallel arithmetic units but require software to decompose multi-precision operations into word-level instructions. The GPU hardware has no awareness of carry dependencies between words, cannot speculatively execute carry-dependent operations, and provides no hardware-level progress tracking for multi-precision operations. Scheduling and load balancing across GPU threads for multi-precision workloads remains a software responsibility.

**RISC-V and general-purpose processors.** The RISC-V instruction set architecture intentionally omits carry and overflow flags to simplify out-of-order execution. While this is architecturally clean, it imposes a penalty on multi-precision arithmetic: each word-level addition requires an additional comparison instruction to detect carry, and the multiply-accumulate inner loop (the hottest path in multi-precision multiplication) requires five instructions where a single fused operation would suffice.

### The Carry Propagation Problem

The fundamental challenge in parallelizing multi-precision arithmetic is carry propagation. When adding two N-word numbers, the carry from word position k may propagate to word position k+1, and potentially cascade through all remaining positions. This sequential dependency appears to prevent parallel execution.

However, statistical analysis shows that for uniformly distributed operands, the expected carry chain length is approximately 1.6 words. The probability that a carry propagates from word k to word k+1 is 2^(-W) where W is the word width (e.g., 2^(-32) for 32-bit words). This observation suggests that speculative execution techniques could be effective for carry propagation, but no existing hardware implements such techniques for multi-precision arithmetic.

### Lack of Operational Observability

Existing systems for computational number theory provide no mechanism for determining the progress of long-running computations. A user initiating a factorization or primality test has no information about the percentage of work completed, the estimated time remaining, or the utilization of compute resources. This is because the software library operates at the word level with no aggregate awareness of the multi-precision operation's progress, and the hardware provides no instrumentation for tracking throughput of higher-level arithmetic operations.


## SUMMARY OF THE INVENTION

The present invention provides a computing architecture, referred to herein as "k-length computing," that addresses the above limitations through the following integrated components:

1. **A variable-length instruction interface** that accepts multi-precision arithmetic operations (addition, subtraction, multiplication, modular reduction) with operand lengths specified as runtime parameters rather than architectural constants.

2. **A decomposition engine** implemented in digital logic that receives variable-length instructions and generates streams of word-level micro-operations with explicit dependency tags encoding carry propagation relationships.

3. **An out-of-order scheduler** that receives micro-operations from the decomposition engine, tracks data dependencies (including carry dependencies) using tag-matching hardware, and issues micro-operations to functional units as their operands become available, regardless of the order in which they were generated.

4. **A carry-aware common data bus (CDB)** that broadcasts both arithmetic results and carry/borrow outputs from functional units, enabling downstream dependent micro-operations to proceed as soon as their specific carry input resolves.

5. **A tag recycling mechanism** using a hardware free-list that reclaims tags from completed micro-operations, enabling operations on operands of unbounded length without exhausting the tag space.

6. **A hardware progress tracking system** that maintains counters for micro-operations issued and completed, providing deterministic progress information for each variable-length operation.

7. **A dispatching mechanism** that routes micro-operations to heterogeneous compute resources including local DSP-based functional units, remote FPGAs, and GPU compute units over a network interface, with the scheduling hardware managing latency-aware placement and dependency resolution across all resource types.


## DETAILED DESCRIPTION OF THE INVENTION

### Overall Architecture

The architecture comprises three processing layers connected by defined interfaces.

**Layer 0 (L0): Word-level custom instructions.** These are single-cycle or short-pipeline instructions that operate on individual machine words (e.g., 32-bit or 64-bit). They are implemented as custom extensions to a RISC-V processor core using the reserved custom opcode space. The L0 instructions include:

- ADDWC (add with carry): Computes rd = rs1 + rs2 + carry_in, producing a carry_out bit. Replaces the two-instruction sequence (add + set-less-than-unsigned) required by standard RISC-V for carry-propagating addition.
- SUBWB (subtract with borrow): Computes rd = rs1 - rs2 - borrow_in, producing a borrow_out bit.
- MULFULL (full multiply): Computes the full double-width product of rs1 and rs2, storing the low word in a general-purpose register and the high word in a dedicated shadow register (HIREG). Backed by DSP multiplication hardware (e.g., DSP48E1 on Xilinx 7-series FPGAs).
- ADDMUL (multiply-accumulate): Computes {HIREG, rd} = rs1 * rs2 + HIREG, where HIREG serves as a running accumulator. This fuses the five-instruction sequence required by standard RISC-V for the multiply-accumulate inner loop into a single instruction.
- DIVDW (double-width divide): Computes the quotient and remainder of a double-width dividend {HIREG, rs1} divided by rs2, using iterative restoring division.
- CLZ (count leading zeros): Computes the number of leading zero bits in rs1 using a combinational priority encoder.

The HIREG shadow register is a dedicated accumulator register accessible only through custom instructions, mirroring the design pattern used by the Pari/GP number theory library's internal "hiremainder" variable.

**Layer 1 (L1): Variable-length operations.** These are multi-precision instructions dispatched from the processor core to the decomposition engine via memory-mapped registers. Each L1 instruction specifies:

- An operation code (e.g., multi-precision add, subtract, multiply, modular multiply)
- Pointers to operand buffers in shared memory
- The length of each operand in words (a runtime value, not an architectural constant)
- A pointer to a result buffer

The processor writes these parameters to a register interface, then asserts a start signal. The decomposition engine processes the operation autonomously and signals completion via interrupt.

**Layer 2 (L2): Algorithm-level operations.** These represent higher-level mathematical operations (e.g., modular exponentiation, greatest common divisor) implemented as sequences of L1 operations coordinated by microcode or software running on the processor core.

### The Decomposition Engine

The decomposition engine is a finite state machine implemented in digital logic that converts L1 variable-length instructions into streams of L0 word-level micro-operations. Its operation proceeds through the following phases:

**IDLE phase.** The engine waits for a command from the processor via the register interface.

**FETCH phase.** The engine reads operand words from shared memory (block RAM or external DRAM) into internal buffers via direct memory access (DMA). The number of words fetched is determined by the length parameters of the L1 instruction.

**GENERATE phase.** The engine emits a stream of L0 micro-operations according to the selected arithmetic algorithm. Each micro-operation includes:

- An L0 opcode (e.g., ADDWC, ADDMUL)
- Source operand values (fetched from the operand buffers)
- A dependency tag identifying the micro-operation on which this one depends (for carry propagation)
- A dependency validity bit indicating whether a dependency exists
- A destination tag assigned to this micro-operation's result
- A destination address in the result buffer

For multi-precision addition of two N-word numbers, the engine generates N ADDWC micro-operations in a linear chain, where micro-operation k depends on the carry output of micro-operation k-1.

For multi-precision multiplication of an Na-word number by an Nb-word number, the engine generates Na * Nb ADDMUL micro-operations organized as Na rows of Nb operations each. Within each row, micro-operation j depends on the carry output of micro-operation j-1. The engine also generates addition micro-operations to accumulate partial products into the result buffer at the appropriate word positions.

The total number of micro-operations is computed at dispatch time and stored in a counter, providing the denominator for progress calculation.

**DRAIN phase.** The engine waits for all outstanding micro-operations to complete, as indicated by the tag recycling free-list returning to its initial count.

**WRITEBACK phase.** The engine transfers results from the scheduler's result accumulation buffer back to the shared memory at the address specified by the L1 instruction.

**DONE phase.** The engine asserts a completion interrupt to the processor and returns to IDLE.

### The Out-of-Order Scheduler

The scheduler receives micro-operations from the decomposition engine and manages their execution across an array of functional units. It is derived from Tomasulo's algorithm for dynamic instruction scheduling, extended with carry-aware dependency tracking.

Each scheduler channel comprises:

- A reservation station table with entries that hold pending micro-operations and their operand/dependency status
- A functional unit (typically a DSP-based multiply-accumulate unit)
- A connection to the common data bus for result broadcasting

A micro-operation enters a reservation station and waits until its dependency (if any) is resolved via a matching tag on the common data bus. Once all dependencies are satisfied, the micro-operation is issued to the functional unit.

The scheduler is parameterized by the number of channels, the number of reservation stations per channel, and the tag width. These parameters are configured at synthesis time to match the target FPGA's resource budget.

### Carry-Aware Common Data Bus

The common data bus (CDB) is extended with a carry bit alongside the standard result data. When a functional unit completes a micro-operation, it broadcasts:

- The result tag (identifying the completed operation)
- The result data (the word-level arithmetic result)
- The carry/borrow output bit

Reservation station entries that depend on the broadcasted tag receive the carry bit as an operand. This enables the next micro-operation in a carry chain to proceed as soon as the carry is resolved, without waiting for the full result word to be written back to memory.

### Speculative Carry Prediction

In an optional enhancement, the scheduler issues carry-dependent micro-operations speculatively, assuming a carry input of zero. If the predecessor micro-operation produces a carry output of one, the scheduler checks whether the speculated result is incorrect (i.e., the result word was at its maximum value and the carry would have changed the outcome). If incorrect, the dependent micro-operation is replayed with the correct carry input.

Because the expected carry chain length for uniformly distributed operands is approximately 1.6 words, the vast majority of speculative executions complete correctly without replay. The scheduler maintains counters for replay events, enabling the passive observation system to monitor speculation effectiveness.

### Tag Recycling Free-List

The tag space is managed by a BRAM-backed circular FIFO that maintains a pool of available tags. Tags are allocated when micro-operations are dispatched and returned to the pool when micro-operations complete. This enables operations on arbitrarily long operands: a multiplication of two 10,000-word numbers generates 100,000,000 micro-operations, but only a bounded number of tags (equal to the maximum number of simultaneously in-flight micro-operations) are required.

The free-list operates in constant time (one cycle for allocation, one cycle for deallocation) and provides a "tags available" count that the decomposition engine uses to throttle micro-operation generation when the in-flight limit is reached.

### Banked Parallel Architecture

For high-throughput implementations, multiple scheduler instances are organized in banks. Each bank contains a configurable number of channels (e.g., 48), and multiple banks (e.g., 8) operate in parallel. A two-stage registered dispatch pipeline distributes micro-operations across banks in a round-robin or dependency-aware pattern, with pipeline registers at bank boundaries to achieve timing closure at elevated clock frequencies.

Results from each bank's CDB are merged through a hierarchical arbitration tree. A shared carry resolution table maintains the global carry state across all banks, ensuring correct carry propagation even when dependent micro-operations execute on different banks.

### Shared Operand Memory

A dual-port block RAM serves as shared memory between the processor and the k-length computing fabric. One port is accessible to the processor for loading operands and reading results. The other port is accessible to the decomposition engine for fetching operands and to the scheduler for writing results. The memory is organized with separate regions for operand A, operand B, and the result buffer.

For implementations requiring operands exceeding the BRAM capacity, an external memory controller (e.g., DDR3 or DDR4 SDRAM) provides extended storage, with the DMA engine managing transfers between external memory and the BRAM working buffers.

### Hardware Progress Tracking

The decomposition engine maintains the following hardware counters:

- **uops_total**: The total number of micro-operations for the current L1 instruction, computed at dispatch time (e.g., Na * Nb for a multiply of Na-word by Nb-word operands).
- **uops_issued**: The number of micro-operations issued to the scheduler.
- **uops_completed**: The number of micro-operations that have completed execution, as indicated by tag recycling events.
- **cycle_count**: A clock cycle counter for the duration of the current operation.

These counters are exposed through memory-mapped registers readable by the processor. The ratio uops_completed / uops_total provides a deterministic progress fraction for any L1 operation, regardless of operand length. The cycle_count value, combined with the observed throughput (uops_completed / cycle_count), enables computation of an estimated time to completion.

For algorithm-level progress (e.g., the number of ECM curves completed out of the statistically expected total), the processor software maintains higher-level counters that complement the hardware operation-level counters.

### Passive Observability Interface

A hardware event logger captures scheduling events including micro-operation dispatch, issue, completion, CDB broadcasts, stall conditions, and carry replay events. Each event is timestamped with clock-cycle precision. Events are buffered in a FIFO and packetized for transmission over a network interface (e.g., UDP over Ethernet).

This telemetry stream enables an external system to observe the internal state of the scheduler in real time, without perturbing its operation. The data can be used for:

- Performance profiling and bottleneck identification
- Training machine learning models to predict scheduling decisions
- Debugging carry propagation and dependency resolution behavior

### Heterogeneous Distributed Execution

The micro-operation dispatch and result collection interfaces are extended to support remote functional units connected via a network protocol. The decomposition engine generates micro-operation batches, which are transmitted to remote compute resources (additional FPGAs, GPUs, or cloud-hosted accelerators). Results are returned via the network and injected into the CDB for dependency resolution.

The scheduler maintains a latency model for each remote resource and routes micro-operations according to a cost function that balances latency against throughput. Independent micro-operations (e.g., separate rows of a multiplication, or separate elliptic curves in an ECM factorization) are preferentially routed to high-throughput remote resources, while latency-sensitive carry chain resolutions are handled by local functional units.

The network protocol between the scheduler and remote resources comprises:

- **BATCH_DISPATCH**: A descriptor containing the batch identifier, number of micro-operations, and for each micro-operation: the opcode, source operands, and dependency tag.
- **BATCH_RESULT**: A descriptor containing the batch identifier and for each completed micro-operation: the result tag, result data, and carry output.

The protocol is designed for amortized low overhead: dispatch and result descriptors are compact (approximately 8 bytes per micro-operation), and batches aggregate thousands of micro-operations per network transaction.

### Checkpoint and Recovery

The decomposition engine maintains a completion bitmap tracking which micro-operations have completed. The processor can read this bitmap and the current engine state to create a checkpoint. If a remote compute resource becomes unavailable (e.g., due to network failure or cloud instance preemption), the outstanding micro-operations assigned to that resource are identified from the completion bitmap and re-dispatched to an alternative resource.

This mechanism enables long-running computations to survive partial hardware failures without losing completed work.

### Algorithm-Specific Decomposition Strategies

The decomposition engine supports multiple algorithms for the same L1 operation, selected based on operand length:

- **Schoolbook multiplication**: For operands below a configurable threshold (e.g., 32 words), the engine generates the straightforward O(n^2) sequence of multiply-accumulate micro-operations.
- **Karatsuba multiplication**: For operands above the threshold, the engine recursively splits operands into halves and generates three sub-multiplications plus recombination additions, reducing the micro-operation count from O(n^2) to O(n^1.585).

The threshold is a synthesis-time or runtime-configurable parameter. The decomposition engine handles the recursive structure, generating micro-operations for each sub-problem with appropriate dependency tags ensuring correct execution order.

### Integration with Existing Number Theory Software

The L0 custom instructions are designed as drop-in replacements for the kernel primitives of the Pari/GP number theory library. Specifically:

- ADDWC replaces the addll/addllx primitives
- MULFULL replaces the mulll primitive
- ADDMUL replaces the addmul primitive
- DIVDW replaces the divll primitive
- CLZ replaces the bfffo primitive

A kernel replacement header file provides C-language inline functions that emit the custom RISC-V instructions, enabling Pari/GP's existing algorithms to execute on the k-length architecture without modification to the higher-level mathematical code.

For L1 operations, the multi-precision inner loops in Pari/GP's kernel (specifically, the muliispec and diviispec routines in the generic kernel) are replaced with single L1 dispatch calls, allowing the hardware decomposition engine to manage word-level scheduling in place of the software loop.


## BRIEF DESCRIPTION OF THE DRAWINGS

The following figures, if included in a subsequent non-provisional application, would illustrate:

FIG. 1: Block diagram of the three-layer k-length computing architecture showing the processor, decomposition engine, out-of-order scheduler, and functional units.

FIG. 2: State machine diagram of the decomposition engine showing IDLE, FETCH, GENERATE, DRAIN, WRITEBACK, and DONE phases.

FIG. 3: Micro-operation dependency graph for multi-precision multiplication, showing carry dependency edges between successive micro-operations within each row of partial products.

FIG. 4: Block diagram of the carry-aware common data bus showing result data, tag, and carry bit propagation.

FIG. 5: Block diagram of the banked parallel architecture showing multiple scheduler banks, the registered dispatch pipeline, and the hierarchical result merge tree.

FIG. 6: Block diagram of the distributed execution architecture showing the FPGA scheduler connected to local functional units and remote GPU/FPGA compute resources via network CDB protocol.

FIG. 7: Timing diagram showing speculative carry prediction, including the common case (speculation correct, no replay) and the uncommon case (carry propagation, replay of affected micro-operation).

FIG. 8: Block diagram of the tag recycling free-list showing the BRAM-backed circular FIFO, allocation interface, and deallocation interface.


## ABSTRACT

A computing architecture for arbitrary-precision arithmetic in which operand length is a runtime parameter rather than an architectural constant. A decomposition engine receives multi-precision arithmetic instructions with variable-length operands and generates streams of word-level micro-operations with explicit carry dependency tags. An out-of-order scheduler, extended with carry-aware dependency tracking, issues micro-operations to an array of functional units as dependencies resolve. A carry-aware common data bus broadcasts both arithmetic results and carry outputs, enabling dependent operations to proceed without unnecessary serialization. A tag recycling mechanism enables operations on operands of unbounded length. Hardware progress counters provide deterministic completion tracking for each operation. The architecture supports heterogeneous distributed execution across local DSP functional units, additional FPGAs, and GPU compute resources, with the scheduling hardware managing dependency resolution across all resource types.
