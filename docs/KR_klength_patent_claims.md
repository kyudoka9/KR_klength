# CLAIMS

## VARIABLE-LENGTH NATIVE ARITHMETIC PROCESSING ARCHITECTURE WITH OUT-OF-ORDER MICRO-OPERATION SCHEDULING

Inventor: H. Ismail


## Independent Claims

**Claim 1.** A digital circuit for performing variable-length arithmetic operations, comprising:

a. a register interface implemented in digital logic, configured to receive from a processor core an arithmetic operation code, memory addresses of first and second operand buffers, a memory address of a result buffer, and a first operand length value and a second operand length value, wherein the first and second operand length values are runtime-variable integers specifying the number of machine words in the respective operands;

b. a decomposition engine implemented as a finite state machine in digital logic, coupled to the register interface and to a shared memory, the decomposition engine configured to:

   i. read a number of operand words from the shared memory determined by the first and second operand length values,

   ii. generate a sequence of word-level micro-operations, each micro-operation comprising a word-level arithmetic opcode, source operand values, a dependency tag identifying a predecessor micro-operation whose carry or borrow output is required, and a destination tag assigned to the micro-operation's own result, wherein the number of micro-operations in the sequence is determined at generation time from the first and second operand length values;

c. an out-of-order scheduler implemented in digital logic, comprising a plurality of reservation station entries and a plurality of functional units, the scheduler configured to:

   i. receive micro-operations from the decomposition engine,

   ii. store each micro-operation in a reservation station entry,

   iii. monitor a common data bus for broadcasts matching the dependency tag of each stored micro-operation,

   iv. issue each micro-operation to a functional unit when its dependency tag has been matched on the common data bus or when no dependency exists; and

d. a common data bus implemented as a registered interconnect in digital logic, configured to broadcast, for each completed micro-operation, the destination tag, a result data word, and a carry output bit, wherein the carry output bit is routed to reservation station entries whose dependency tag matches the destination tag.


**Claim 2.** A method of executing variable-length arithmetic operations in a digital circuit comprising a decomposition engine, an out-of-order scheduler with reservation stations, a plurality of functional units, and a common data bus, the method comprising:

a. receiving, at the decomposition engine, an instruction specifying an arithmetic operation, memory addresses of operand buffers, and operand length values expressed as numbers of machine words;

b. reading, by the decomposition engine, operand words from a shared memory, the number of words read being determined by the operand length values;

c. generating, by the decomposition engine, a sequence of word-level micro-operations from the read operand words, each micro-operation comprising source operands, a dependency tag referencing a predecessor micro-operation's carry output, and a destination tag, wherein the total count of micro-operations is computed from the operand length values at generation time;

d. issuing, by the out-of-order scheduler, each micro-operation to a functional unit when its dependency tag has been satisfied by a prior broadcast on the common data bus or when no dependency exists;

e. broadcasting, by each functional unit upon completion, the destination tag, the computed result data, and a carry output bit on the common data bus;

f. matching, by reservation station hardware, the broadcasted destination tag against the dependency tags of waiting micro-operations, and forwarding the carry output bit to the matched micro-operations as an input operand; and

g. writing result words to the shared memory at addresses determined by the decomposition engine.


**Claim 3.** A digital circuit for tracking progress of variable-length arithmetic operations, comprising:

a. a decomposition engine implemented in digital logic, configured to receive arithmetic instructions with runtime-variable operand length parameters, and to compute, prior to commencing execution, a total count of word-level micro-operations required to complete the instruction, the total count being a deterministic function of the operand length parameters;

b. a first hardware counter that increments each time a micro-operation is issued to a scheduler;

c. a second hardware counter that increments each time a micro-operation completes execution, as indicated by a tag recycling event on a hardware free-list;

d. a cycle counter that increments each clock cycle during execution of the instruction; and

e. a set of memory-mapped registers exposing the total count, the first counter value, the second counter value, and the cycle counter value to the processor core, enabling the processor to compute a progress fraction as the ratio of the second counter value to the total count, and an estimated time to completion from the observed throughput.


## Dependent Claims

**Claim 4.** The digital circuit of claim 1, wherein the decomposition engine is further configured to select, based on the operand length values, between a first decomposition algorithm that generates O(n^2) micro-operations and a second decomposition algorithm that recursively splits operands and generates O(n^1.585) micro-operations, where n is the larger of the two operand length values, the selection being determined by comparison of n against a configurable threshold value stored in a register.


**Claim 5.** The digital circuit of claim 1, further comprising a tag recycling free-list implemented as a BRAM-backed circular FIFO in digital logic, the free-list configured to:

a. maintain a pool of available destination tags;

b. allocate a tag to each micro-operation generated by the decomposition engine by reading from the FIFO head;

c. return a tag to the pool when the corresponding micro-operation completes execution, by writing to the FIFO tail; and

d. provide a count of available tags to the decomposition engine, the decomposition engine being configured to stall micro-operation generation when the available tag count falls below a threshold,

wherein the tag recycling enables the circuit to process operands of length exceeding the tag space capacity by reusing tags from completed micro-operations.


**Claim 6.** The digital circuit of claim 1, wherein the out-of-order scheduler is further configured to:

a. issue a carry-dependent micro-operation speculatively, using a default carry input value of zero, before the predecessor micro-operation's carry output is available on the common data bus;

b. upon receiving the predecessor micro-operation's actual carry output on the common data bus, determine whether the speculative result is incorrect by checking whether the carry output is non-zero and the speculative result word equals its maximum representable value; and

c. upon determining that the speculative result is incorrect, replay the micro-operation with the correct carry input value and broadcast the corrected result on the common data bus.


**Claim 7.** The digital circuit of claim 6, wherein the scheduler further comprises a replay counter that increments each time a speculative micro-operation is replayed, and wherein the replay counter value is exposed to the passive observation interface defined in claim 12.


**Claim 8.** The digital circuit of claim 1, wherein the plurality of functional units comprises multiply-accumulate units implemented using DSP hard macros of a field-programmable gate array, each multiply-accumulate unit configured to compute the fused operation {high_word, low_word} = rs1 * rs2 + accumulator in a fixed number of pipeline stages, wherein the number of pipeline stages corresponds to the registered pipeline depth of the DSP hard macro.


**Claim 9.** The digital circuit of claim 1, wherein the out-of-order scheduler is organized into a plurality of banks, each bank comprising a configurable number of scheduler channels with associated functional units and a local common data bus, the circuit further comprising:

a. a registered dispatch pipeline that distributes micro-operations from the decomposition engine to banks, with pipeline register stages at bank boundaries;

b. a hierarchical result arbitration tree that merges completed micro-operation broadcasts from per-bank common data buses into a unified result stream; and

c. a shared carry resolution table, accessible by all banks, that maintains carry state for multi-precision operations spanning multiple banks.


**Claim 10.** The digital circuit of claim 1, further comprising a dispatch interface configured to transmit micro-operation batches to remote compute resources over a network connection, the dispatch interface comprising:

a. a batch accumulator that collects independent micro-operations (those having no unresolved dependencies on pending local micro-operations) into a batch descriptor;

b. a network transmitter that sends the batch descriptor to a remote compute resource;

c. a network receiver that receives batch result descriptors from the remote compute resource, each batch result descriptor containing, for each completed micro-operation, the destination tag, result data, and carry output bit; and

d. injection logic that places received results onto the local common data bus for dependency resolution,

wherein the scheduler's reservation station hardware resolves dependencies between locally executed and remotely executed micro-operations using the same tag-matching mechanism.


**Claim 11.** The digital circuit of claim 10, further comprising a latency estimator for each remote compute resource, the latency estimator maintaining a running average of round-trip dispatch-to-result time, and wherein the decomposition engine routes micro-operations to local functional units when the micro-operation has a dependency on a pending local micro-operation with an estimated completion time less than the remote resource's latency, and routes micro-operations to remote resources when the micro-operation is independent and the remote resource has available capacity.


**Claim 12.** The digital circuit of claim 1, further comprising a passive observation interface implemented in digital logic, comprising:

a. an event capture unit that records, for each scheduling event, an event type identifier, a channel identifier, relevant tag values, and a timestamp derived from a clock cycle counter;

b. a FIFO buffer that stores captured events; and

c. a packetizer that reads events from the FIFO buffer and formats them into network packets for transmission over a network interface,

wherein the scheduling events captured include at least: micro-operation dispatch events, micro-operation issue events, micro-operation completion events, common data bus broadcast events, scheduler stall events, and carry replay events, and wherein the event capture does not insert wait states or otherwise affect the timing of the scheduler's operation.


**Claim 13.** The digital circuit of claim 1, further comprising a completion bitmap implemented in digital logic, the completion bitmap having one bit per outstanding micro-operation tag, each bit being set when the corresponding micro-operation completes execution, and wherein the processor core can read the completion bitmap and current decomposition engine state to create a checkpoint, enabling resumption of a partially completed variable-length operation after reassignment of outstanding micro-operations to alternative functional units or remote compute resources.


**Claim 14.** The digital circuit of claim 1, wherein the L0 word-level arithmetic opcodes include:

a. an add-with-carry opcode (ADDWC) that computes the sum of two source registers and a carry input bit, producing a result register value and a carry output bit, in a single clock cycle;

b. a subtract-with-borrow opcode (SUBWB) that computes the difference of two source registers with a borrow input bit, producing a result register value and a borrow output bit, in a single clock cycle;

c. a full-multiply opcode (MULFULL) that computes the full double-width product of two source registers, storing the low word in a destination register and the high word in a shadow accumulator register, using a DSP hard macro pipeline;

d. a multiply-accumulate opcode (ADDMUL) that computes the product of two source registers added to the current value of the shadow accumulator register, storing the low word in a destination register and the updated high word in the shadow accumulator register; and

e. a double-width divide opcode (DIVDW) that computes the quotient and remainder of a double-width dividend formed by the shadow accumulator register concatenated with a source register, divided by a second source register, using iterative restoring division logic.


**Claim 15.** The digital circuit of claim 14, wherein the shadow accumulator register is a dedicated register internal to a custom function unit of the processor core, accessible only through the MULFULL, ADDMUL, and DIVDW opcodes and through explicit read (RDHIREG) and write (WRHIREG) opcodes, and not part of the processor's general-purpose register file.


**Claim 16.** The method of claim 2, further comprising:

a. prior to generating micro-operations, computing the total count of micro-operations from the operand length values;

b. maintaining in hardware a counter of completed micro-operations;

c. exposing the total count and the completed count through memory-mapped registers; and

d. computing, by the processor core, a progress fraction as the ratio of completed count to total count, and an estimated time remaining as the product of remaining micro-operations and the observed average cycle count per micro-operation.


**Claim 17.** The method of claim 2, wherein generating the sequence of word-level micro-operations for a multi-precision multiplication of an Na-word operand by an Nb-word operand comprises:

a. for each word index i from 0 to Na-1, and for each word index j from 0 to Nb-1, generating a multiply-accumulate micro-operation with source operands A[i] and B[j], with a dependency tag referencing the carry output of the micro-operation generated for indices (i, j-1) when j > 0, and with a destination address corresponding to result word position i+j; and

b. for each row i, generating a carry-out micro-operation that propagates the final carry of the row to result word position i+Nb.


**Claim 18.** The digital circuit of claim 3, wherein the progress tracking circuit further comprises an algorithm-level progress interface, implemented as a set of memory-mapped registers writable by the processor core, configured to store:

a. an algorithm phase identifier;

b. an iteration count representing the number of algorithm-level iterations completed (e.g., elliptic curves evaluated in ECM factorization); and

c. an expected iteration count representing the statistically estimated total iterations,

and wherein the processor core updates these registers during algorithm execution, enabling a display of both operation-level progress (from hardware counters) and algorithm-level progress (from software-maintained counters) simultaneously.
