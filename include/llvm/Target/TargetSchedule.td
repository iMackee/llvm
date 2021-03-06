//===- TargetSchedule.td - Target Independent Scheduling ---*- tablegen -*-===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This file defines the target-independent scheduling interfaces which should
// be implemented by each target which is using TableGen based scheduling.
//
// The SchedMachineModel is defined by subtargets for three categories of data:
// 1. Basic properties for coarse grained instruction cost model.
// 2. Scheduler Read/Write resources for simple per-opcode cost model.
// 3. Instruction itineraties for detailed reservation tables.
//
// (1) Basic properties are defined by the SchedMachineModel
// class. Target hooks allow subtargets to associate opcodes with
// those properties.
//
// (2) A per-operand machine model can be implemented in any
// combination of the following ways:
//
// A. Associate per-operand SchedReadWrite types with Instructions by
// modifying the Instruction definition to inherit from Sched. For
// each subtarget, define WriteRes and ReadAdvance to associate
// processor resources and latency with each SchedReadWrite type.
//
// B. In each instruction definition, name an ItineraryClass. For each
// subtarget, define ItinRW entries to map ItineraryClass to
// per-operand SchedReadWrite types. Unlike method A, these types may
// be subtarget specific and can be directly associated with resources
// by defining SchedWriteRes and SchedReadAdvance.
//
// C. In the subtarget, map SchedReadWrite types to specific
// opcodes. This overrides any SchedReadWrite types or
// ItineraryClasses defined by the Instruction. As in method B, the
// subtarget can directly associate resources with SchedReadWrite
// types by defining SchedWriteRes and SchedReadAdvance.
//
// D. In either the target or subtarget, define SchedWriteVariant or
// SchedReadVariant to map one SchedReadWrite type onto another
// sequence of SchedReadWrite types. This allows dynamic selection of
// an instruction's machine model via custom C++ code. It also allows
// a machine-independent SchedReadWrite type to map to a sequence of
// machine-dependent types.
//
// (3) A per-pipeline-stage machine model can be implemented by providing
// Itineraries in addition to mapping instructions to ItineraryClasses.
//===----------------------------------------------------------------------===//

// Include legacy support for instruction itineraries.
include "llvm/Target/TargetItinerary.td"

class Instruction; // Forward def

// DAG operator that interprets the DAG args as Instruction defs.
def instrs;

// DAG operator that interprets each DAG arg as a regex pattern for
// matching Instruction opcode names.
// The regex must match the beginning of the opcode (as in Python re.match).
// To avoid matching prefixes, append '$' to the pattern.
def instregex;

// Define the SchedMachineModel and provide basic properties for
// coarse grained instruction cost model. Default values for the
// properties are defined in MCSchedModel. A value of "-1" in the
// target description's SchedMachineModel indicates that the property
// is not overriden by the target.
//
// Target hooks allow subtargets to associate LoadLatency and
// HighLatency with groups of opcodes.
class SchedMachineModel {
  int IssueWidth = -1; // Max micro-ops that may be scheduled per cycle.
  int MinLatency = -1; // Determines which instrucions are allowed in a group.
                       // (-1) inorder (0) ooo, (1): inorder +var latencies.
  int ILPWindow = -1;  // Cycles of latency likely hidden by hardware buffers.
  int LoadLatency = -1; // Cycles for loads to access the cache.
  int HighLatency = -1; // Approximation of cycles for "high latency" ops.
  int MispredictPenalty = -1; // Extra cycles for a mispredicted branch.

  // Per-cycle resources tables.
  ProcessorItineraries Itineraries = NoItineraries;

  bit NoModel = 0; // Special tag to indicate missing machine model.
}

def NoSchedModel : SchedMachineModel {
  let NoModel = 1;
}

// Define a kind of processor resource that may be common across
// similar subtargets.
class ProcResourceKind;

// Define a number of interchangeable processor resources. NumUnits
// determines the throughput of instructions that require the resource.
//
// An optional Super resource may be given to model these resources as
// a subset of the more general super resources. Using one of these
// resources implies using one of the super resoruces.
//
// ProcResourceUnits normally model a few buffered resources within an
// out-of-order engine that the compiler attempts to conserve.
// Buffered resources may be held for multiple clock cycles, but the
// scheduler does not pin them to a particular clock cycle relative to
// instruction dispatch. Setting Buffered=0 changes this to an
// in-order resource. In this case, the scheduler counts down from the
// cycle that the instruction issues in-order, forcing an interlock
// with subsequent instructions that require the same resource until
// the number of ResourceCyles specified in WriteRes expire.
//
// SchedModel ties these units to a processor for any stand-alone defs
// of this class. Instances of subclass ProcResource will be automatically
// attached to a processor, so SchedModel is not needed.
class ProcResourceUnits<ProcResourceKind kind, int num> {
  ProcResourceKind Kind = kind;
  int NumUnits = num;
  ProcResourceKind Super = ?;
  bit Buffered = 1;
  SchedMachineModel SchedModel = ?;
}

// EponymousProcResourceKind helps implement ProcResourceUnits by
// allowing a ProcResourceUnits definition to reference itself. It
// should not be referenced anywhere else.
def EponymousProcResourceKind : ProcResourceKind;

// Subtargets typically define processor resource kind and number of
// units in one place.
class ProcResource<int num> : ProcResourceKind,
  ProcResourceUnits<EponymousProcResourceKind, num>;

// A target architecture may define SchedReadWrite types and associate
// them with instruction operands.
class SchedReadWrite;

// List the per-operand types that map to the machine model of an
// instruction. One SchedWrite type must be listed for each explicit
// def operand in order. Additional SchedWrite types may optionally be
// listed for implicit def operands.  SchedRead types may optionally
// be listed for use operands in order. The order of defs relative to
// uses is insignificant. This way, the same SchedReadWrite list may
// be used for multiple forms of an operation. For example, a
// two-address instruction could have two tied operands or single
// operand that both reads and writes a reg. In both cases we have a
// single SchedWrite and single SchedRead in any order.
class Sched<list<SchedReadWrite> schedrw> {
  list<SchedReadWrite> SchedRW = schedrw;
}

// Define a scheduler resource associated with a def operand.
class SchedWrite : SchedReadWrite;
def NoWrite : SchedWrite;

// Define a scheduler resource associated with a use operand.
class SchedRead  : SchedReadWrite;

// Define a SchedWrite that is modeled as a sequence of other
// SchedWrites with additive latency. This allows a single operand to
// be mapped the resources composed from a set of previously defined
// SchedWrites.
//
// If the final write in this sequence is a SchedWriteVariant marked
// Variadic, then the list of prior writes are distributed across all
// operands after resolving the predicate for the final write.
//
// SchedModel silences warnings but is ignored.
class WriteSequence<list<SchedWrite> writes, int rep = 1> : SchedWrite {
  list<SchedWrite> Writes = writes;
  int Repeat = rep;
  SchedMachineModel SchedModel = ?;
}

// Define values common to WriteRes and SchedWriteRes.
//
// SchedModel ties these resources to a processor.
class ProcWriteResources<list<ProcResourceKind> resources> {
  list<ProcResourceKind> ProcResources = resources;
  list<int> ResourceCycles = [];
  int Latency = 1;
  int NumMicroOps = 1;
  bit BeginGroup = 0;
  bit EndGroup = 0;
  // Allow a processor to mark some scheduling classes as unsupported
  // for stronger verification.
  bit Unsupported = 0;
  SchedMachineModel SchedModel = ?;
}

// Define the resources and latency of a SchedWrite. This will be used
// directly by targets that have no itinerary classes. In this case,
// SchedWrite is defined by the target, while WriteResources is
// defined by the subtarget, and maps the SchedWrite to processor
// resources.
//
// If a target already has itinerary classes, SchedWriteResources can
// be used instead to define subtarget specific SchedWrites and map
// them to processor resources in one place. Then ItinRW can map
// itinerary classes to the subtarget's SchedWrites.
//
// ProcResources indicates the set of resources consumed by the write.
// Optionally, ResourceCycles indicates the number of cycles the
// resource is consumed. Each ResourceCycles item is paired with the
// ProcResource item at the same position in its list. Since
// ResourceCycles are rarely specialized, the list may be
// incomplete. By default, resources are consumed for a single cycle,
// regardless of latency, which models a fully pipelined processing
// unit. A value of 0 for ResourceCycles means that the resource must
// be available but is not consumed, which is only relevant for
// unbuffered resources.
//
// By default, each SchedWrite takes one micro-op, which is counted
// against the processor's IssueWidth limit. If an instruction can
// write multiple registers with a single micro-op, the subtarget
// should define one of the writes to be zero micro-ops. If a
// subtarget requires multiple micro-ops to write a single result, it
// should either override the write's NumMicroOps to be greater than 1
// or require additional writes. Extra writes can be required either
// by defining a WriteSequence, or simply listing extra writes in the
// instruction's list of writers beyond the number of "def"
// operands. The scheduler assumes that all micro-ops must be
// dispatched in the same cycle. These micro-ops may be required to
// begin or end the current dispatch group.
class WriteRes<SchedWrite write, list<ProcResourceKind> resources>
  : ProcWriteResources<resources> {
  SchedWrite WriteType = write;
}

// Directly name a set of WriteResources defining a new SchedWrite
// type at the same time. This class is unaware of its SchedModel so
// must be referenced by InstRW or ItinRW.
class SchedWriteRes<list<ProcResourceKind> resources> : SchedWrite,
  ProcWriteResources<resources>;

// Define values common to ReadAdvance and SchedReadAdvance.
//
// SchedModel ties these resources to a processor.
class ProcReadAdvance<int cycles, list<SchedWrite> writes = []> {
  int Cycles = cycles;
  list<SchedWrite> ValidWrites = writes;
  // Allow a processor to mark some scheduling classes as unsupported
  // for stronger verification.
  bit Unsupported = 0;
  SchedMachineModel SchedModel = ?;
}

// A processor may define a ReadAdvance associated with a SchedRead
// to reduce latency of a prior write by N cycles. A negative advance
// effectively increases latency, which may be used for cross-domain
// stalls.
//
// A ReadAdvance may be associated with a list of SchedWrites
// to implement pipeline bypass. The Writes list may be empty to
// indicate operands that are always read this number of Cycles later
// than a normal register read, allowing the read's parent instruction
// to issue earlier relative to the writer.
class ReadAdvance<SchedRead read, int cycles, list<SchedWrite> writes = []>
  : ProcReadAdvance<cycles, writes> {
  SchedRead ReadType = read;
}

// Directly associate a new SchedRead type with a delay and optional
// pipeline bypess. For use with InstRW or ItinRW.
class SchedReadAdvance<int cycles, list<SchedWrite> writes = []> : SchedRead,
  ProcReadAdvance<cycles, writes>;

// Define SchedRead defaults. Reads seldom need special treatment.
def ReadDefault : SchedRead;
def NoReadAdvance : SchedReadAdvance<0>;

// Define shared code that will be in the same scope as all
// SchedPredicates. Available variables are:
// (const MachineInstr *MI, const TargetSchedModel *SchedModel)
class PredicateProlog<code c> {
  code Code = c;
}

// Define a predicate to determine which SchedVariant applies to a
// particular MachineInstr. The code snippet is used as an
// if-statement's expression. Available variables are MI, SchedModel,
// and anything defined in a PredicateProlog.
//
// SchedModel silences warnings but is ignored.
class SchedPredicate<code pred> {
  SchedMachineModel SchedModel = ?;
  code Predicate = pred;
}
def NoSchedPred : SchedPredicate<[{true}]>;

// Associate a predicate with a list of SchedReadWrites. By default,
// the selected SchedReadWrites are still associated with a single
// operand and assumed to execute sequentially with additive
// latency. However, if the parent SchedWriteVariant or
// SchedReadVariant is marked "Variadic", then each Selected
// SchedReadWrite is mapped in place to the instruction's variadic
// operands. In this case, latency is not additive. If the current Variant
// is already part of a Sequence, then that entire chain leading up to
// the Variant is distributed over the variadic operands.
class SchedVar<SchedPredicate pred, list<SchedReadWrite> selected> {
  SchedPredicate Predicate = pred;
  list<SchedReadWrite> Selected = selected;
}

// SchedModel silences warnings but is ignored.
class SchedVariant<list<SchedVar> variants> {
  list<SchedVar> Variants = variants;
  bit Variadic = 0;
  SchedMachineModel SchedModel = ?;
}

// A SchedWriteVariant is a single SchedWrite type that maps to a list
// of SchedWrite types under the conditions defined by its predicates.
//
// A Variadic write is expanded to cover multiple "def" operands. The
// SchedVariant's Expansion list is then interpreted as one write
// per-operand instead of the usual sequential writes feeding a single
// operand.
class SchedWriteVariant<list<SchedVar> variants> : SchedWrite,
  SchedVariant<variants> {
}

// A SchedReadVariant is a single SchedRead type that maps to a list
// of SchedRead types under the conditions defined by its predicates.
//
// A Variadic write is expanded to cover multiple "readsReg" operands as
// explained above.
class SchedReadVariant<list<SchedVar> variants> : SchedRead,
  SchedVariant<variants> {
}

// Map a set of opcodes to a list of SchedReadWrite types. This allows
// the subtarget to easily override specific operations.
//
// SchedModel ties this opcode mapping to a processor.
class InstRW<list<SchedReadWrite> rw, dag instrlist> {
  list<SchedReadWrite> OperandReadWrites = rw;
  dag Instrs = instrlist;
  SchedMachineModel SchedModel = ?;
}

// Map a set of itinerary classes to SchedReadWrite resources. This is
// used to bootstrap a target (e.g. ARM) when itineraries already
// exist and changing InstrInfo is undesirable.
//
// SchedModel ties this ItineraryClass mapping to a processor.
class ItinRW<list<SchedReadWrite> rw, list<InstrItinClass> iic> {
  list<InstrItinClass> MatchedItinClasses = iic;
  list<SchedReadWrite> OperandReadWrites = rw;
  SchedMachineModel SchedModel = ?;
}

// Alias a target-defined SchedReadWrite to a processor specific
// SchedReadWrite. This allows a subtarget to easily map a
// SchedReadWrite type onto a WriteSequence, SchedWriteVariant, or
// SchedReadVariant.
//
// SchedModel will usually be provided by surrounding let statement
// and ties this SchedAlias mapping to a processor.
class SchedAlias<SchedReadWrite match, SchedReadWrite alias> {
  SchedReadWrite MatchRW = match;
  SchedReadWrite AliasRW = alias;
  SchedMachineModel SchedModel = ?;
}
