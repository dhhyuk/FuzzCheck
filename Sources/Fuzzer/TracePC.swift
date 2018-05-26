
import CBuiltinsNotAvailableInSwift
import Darwin

typealias Feature = Int

// TableOfRecentCompares (TORC) remembers the most recently performed
// comparisons of type T.
// We record the arguments of CMP instructions in this table unconditionally
// because it seems cheaper this way than to compute some expensive
// conditions inside __sanitizer_cov_trace_cmp*.
// After the unit has been executed we may decide to use the contents of
// this table to populate a Dictionary.
struct TableOfRecentCompares <T> {
    static var size: Int { return 32 } // kSizeT
    // TODO: use sourcery to avoid using the heap
    //       or use unsafe pointers or whatever, just make it fast
    var table: [(T, T)?]
    init() {
        self.table = Array(repeating: nil, count: TableOfRecentCompares.size)
    }
    
    subscript(idx: Int) -> (T, T) {
        get {
            return table[idx % TableOfRecentCompares.size]!
        }
        set {
            table[idx % TableOfRecentCompares.size] = newValue
        }
    }
}

/*
template <Int kSizeT>
struct MemMemTable {
  static const Int kSize = kSizeT;
  Word MemMemWords[kSize];
  Word EmptyWord;

  void Add(const uint8_t *Data, Int Size) {
    if (Size <= 2) return;
    Size = std::min(Size, Word::GetMaxSize());
    Int Idx = SimpleFastHash(Data, Size) % kSize;
    MemMemWords[Idx].Set(Data, Size);
  }
  const Word &Get(Int Idx) {
    for (Int i = 0; i < kSize; i++) {
      const Word &W = MemMemWords[(Idx + i) % kSize];
      if (W.size()) return W;
    }
    EmptyWord.Set(nullptr, 0);
    return EmptyWord;
  }
};
*/

// The coverage counters and PCs.
// These are declared as global variables named "__sancov_*" to simplify
// experiments with inlined instrumentation.

extension UnsafeMutableBufferPointer {
    static func allocateAndInitializeTo(_ x: Element, capacity: Int) -> UnsafeMutableBufferPointer {
        let b = UnsafeMutableBufferPointer.allocate(capacity: capacity)
        b.initialize(repeating: x)
        return b
    }
}

// __sancov_trace_pc_pcs
var PCs = UnsafeMutableBufferPointer<PC>.allocateAndInitializeTo(0, capacity: TracePC.maxNumPCs)
// __sancov_trace_pc_guard_8bit_counters
var eightBitCounters = UnsafeMutableBufferPointer<UInt8>.allocateAndInitializeTo(0, capacity: TracePC.maxNumPCs)

func counterToFeature <T: BinaryInteger> (_ counter: T) -> CUnsignedInt {
    precondition(counter > 0)
   
    if counter >= 128 { return 7 }
    if counter >= 32  { return 6 }
    if counter >= 16  { return 5 }
    if counter >= 8   { return 4 }
    if counter >= 4   { return 3 }
    if counter >= 3   { return 2 }
    if counter >= 2   { return 1 }
    return 0
}

struct PCTableEntry {
    let pc: PC
    let flags: UInt;
}

typealias PC = UInt
extension PC {
    var positive: Bool {
        return self > 0
    }
}

final class TracePC {
    // How many bits of PC are used from __sanitizer_cov_trace_pc
    static let maxNumPCs: Int = 1 << 21
    static let tracePCBits: Int = 18
    
    var numGuards: Int = 0
    var modules: [UnsafeMutableBufferPointer<UInt32>] = []
    
    var modulePCTables: [UnsafeMutableBufferPointer<PCTableEntry>] = []
    var numPCInPCTables: Int = 0
    
    var numInline8bitCounters: Int = 0
    var numModulesWithInline8BitCounters: Int = 0
    
    var valueProfileMap: ValueBitMap = .init()
    
    var observedPCs: Set<PC> = []
    var observedFuncs: Set<PC> = []
    
    var useCounters: Bool = false
    var useValueProfile: Bool = false
    var printNewPCs: Bool = false
    var printNewFuncs: Int = 0
    
    var moduleCounters: [UnsafeMutableBufferPointer<UInt8>] = []
    
    var torc4: TableOfRecentCompares<UInt32> = .init()
    var torc8: TableOfRecentCompares<UInt64> = .init()
    // let torcW: TableOfRecentCompares<CUnsignedInt>
    // MemMemTable<1024> MMT;
    
    init() {}
    
    func numPCs() -> Int {
        if numGuards == 0 {
            return 1 << TracePC.tracePCBits
        } else {
            return min(TracePC.maxNumPCs, numGuards+1)
        }
    }
    
    func handleInit(start: UnsafeMutablePointer<UInt32>, stop: UnsafeMutablePointer<UInt32>) {
        guard start != stop && start.pointee == 0 else { return }
    
        let buffer = UnsafeMutableBufferPointer(start: start, count: stop - start)
        for i in buffer.indices {
            numGuards += 1
            if numGuards == TracePC.maxNumPCs {
                print("""
                WARNING: The binary has too many instrumented PCs.
                         You may want to reduce the size of the binary
                         for more efficient fuzzing and precise coverage data
                """)
            }
            buffer[i] = UInt32(numGuards % TracePC.maxNumPCs)
        }
        modules.append(buffer)
        
        /*
if (Start == Stop || *Start) return;
  assert(NumModules < sizeof(Modules) / sizeof(Modules[0]));
  for (uint32_t *P = Start; P < Stop; P++) {
    NumGuards++;
    if (NumGuards == kNumPCs) {
      RawPrint(
          "WARNING: The binary has too many instrumented PCs.\n"
          "         You may want to reduce the size of the binary\n"
          "         for more efficient fuzzing and precise coverage data\n");
    }
    *P = NumGuards % kNumPCs;
  }
  Modules[NumModules].Start = Start;
  Modules[NumModules].Stop = Stop;
  NumModules++;
         */
    }
    
    func handlePCsInit(start: UnsafeMutablePointer<PCTableEntry>, stop: UnsafeMutablePointer<PCTableEntry>) {
        guard let l = modulePCTables.last, l.baseAddress != start else { return }
        // precondition
        let buffer = UnsafeMutableBufferPointer(start: start, count: stop - start)
        modulePCTables.append(buffer)
        numPCInPCTables += buffer.count
    }
    
    func handleCallerCallee(caller: UInt, callee: UInt) {
        let bits: UInt = 12
        let mask = (1 << bits) - 1
        let idx: UInt = (caller & mask) | ((callee & mask) << bits)
        _ = valueProfileMap.addValueModPrime(idx)
    }
    
    func getTotalPCCoverage() -> Int {
        guard !observedPCs.isEmpty else {
            return (1 ..< numPCs()).reduce(0) { $0 + (PCs[$1].positive ? 1 : 0) }
        }
        return observedPCs.count
    }
    
    func updateObservedPCs() {
        var coveredFuncs: [PC] = []
        
        func observePC(_ pc: PC) {
            if observedPCs.insert(pc).inserted, printNewPCs {
                print("\tNEW_PC: TODO")// TODO
            }
        }
        
        func observe(_ TE: PCTableEntry) {
            if TE.flags & 1 != 0, observedFuncs.insert(TE.pc).inserted, printNewFuncs != 0 {
                coveredFuncs.append(TE.pc)
            }
            observePC(TE.pc)
        }
        
        if numPCInPCTables != 0 {
            if numInline8bitCounters == numPCInPCTables {
                for i in 0 ..< numModulesWithInline8BitCounters {
                    precondition(moduleCounters[i].count == modulePCTables[i].count)
                    for j in moduleCounters[i].indices where moduleCounters[i][j] > 0 {
                        observe(modulePCTables[i][j])
                    }
                }
            }
        } else if numGuards == numPCInPCTables {
            var guardIdx = 1
            for i in modules.indices {
                for j in modules[i].indices {
                    guardIdx += 1
                    if eightBitCounters[guardIdx] != 0 {
                        observe(modulePCTables[i][j])
                    }
                }
            }
        }
        // skip clang counters parts
        for _ in 0 ..< min(coveredFuncs.count, printNewFuncs) {
            // print
            // TODO
        }
    }
    
    func collectFeatures(_ handleFeature: (Feature) -> Void) {
        let Counters = eightBitCounters
        let N = numPCs()
        
        func handle8BitCounter(_ handleFeature: (Feature) -> Void, _ firstFeature: Feature, _ idx: Int, _ counter: UInt8) -> Void {
            handleFeature(firstFeature + idx/* * 8*/ + Int(counterToFeature(counter)))
        }
        
        var firstFeature: Feature = 0
        if numInline8bitCounters == 0 {
            for i in 0 ..< N where Counters[i] != 0 {
                handle8BitCounter(handleFeature, firstFeature, i, Counters[i])
            }
            firstFeature += N/* * 8*/
        }
        else {
            var x = 0
            for i in 0 ..< numModulesWithInline8BitCounters {
                for j in moduleCounters[i].indices where moduleCounters[i][j] != 0 {
                    x += 1
                    handle8BitCounter(handleFeature, firstFeature, j, moduleCounters[i][j])
                }
            }
            print(x)
        }
        // omit clang counters
        // omit extra counters
        if useValueProfile {
            valueProfileMap.forEach {
                handleFeature(firstFeature + $0)
            }
            firstFeature += Feature(type(of: valueProfileMap).mapSizeInBits)
        }
        
        // omit lowest stack thingy
    }
    
    /*
void TracePC::CollectFeatures(Callback HandleFeature) const {
  uint8_t *Counters = this->Counters();
  Int N = GetNumPCs();
  auto Handle8bitCounter = [&](Int FirstFeature,
                               Int Idx, uint8_t Counter) {
    HandleFeature(FirstFeature + Idx * 8 + CounterToFeature(Counter));
  };

  Int FirstFeature = 0;

  if (!NumInline8bitCounters) {
    ForEachNonZeroByte(Counters, Counters + N, FirstFeature, Handle8bitCounter);
    FirstFeature += N * 8;
  }

  if (NumInline8bitCounters) {
    for (Int i = 0; i < NumModulesWithInline8bitCounters; i++) {
      ForEachNonZeroByte(ModuleCounters[i].Start, ModuleCounters[i].Stop,
                         FirstFeature, Handle8bitCounter);
      FirstFeature += 8 * (ModuleCounters[i].Stop - ModuleCounters[i].Start);
    }
  }

  if (Int NumClangCounters = ClangCountersEnd() - ClangCountersBegin()) {
    auto P = ClangCountersBegin();
    for (Int Idx = 0; Idx < NumClangCounters; Idx++)
      if (auto Cnt = P[Idx])
        HandleFeature(FirstFeature + Idx * 8 + CounterToFeature(Cnt));
    FirstFeature += NumClangCounters;
  }

  ForEachNonZeroByte(ExtraCountersBegin(), ExtraCountersEnd(), FirstFeature,
                     Handle8bitCounter);
  FirstFeature += (ExtraCountersEnd() - ExtraCountersBegin()) * 8;

  if (UseValueProfile) {
    ValueProfileMap.ForEach([&](Int Idx) {
      HandleFeature(FirstFeature + Idx);
    });
    FirstFeature += ValueProfileMap.SizeInBits();
  }

  if (auto MaxStackOffset = GetMaxStackOffset())
    HandleFeature(FirstFeature + MaxStackOffset);
}

     */
    
    func handleInline8BitCountersInit(start: UnsafeMutablePointer<UInt8>, stop: UnsafeMutablePointer<UInt8>) {
        guard start != stop else { return }
        guard !(numModulesWithInline8BitCounters != 0 && moduleCounters.last!.baseAddress == start) else {
            return
        }
        precondition(numModulesWithInline8BitCounters < moduleCounters.count)
        let buffer = UnsafeMutableBufferPointer(start: start, count: stop - start)
        moduleCounters[numModulesWithInline8BitCounters] = buffer
        numInline8bitCounters += buffer.count
    }

    func handleCmp <T: BinaryInteger> (pc: PC, arg1: T, arg2: T) {
        let argxor = arg1 ^ arg2
        let argdist = UInt(__popcountll(UInt64(argxor)) + 1)

        let idx = ((pc & 4095) + 1) &* argdist
        if let (arg1, arg2) = (arg1, arg2) as? (UInt32, UInt32) {
            torc4[numericCast(argxor)] = (arg1, arg2)
        } else if let (arg1, arg2) = (arg1, arg2) as? (UInt64, UInt64) {
            torc8[numericCast(argxor % (T(Int.max)))] = (arg1, arg2)
        }
        _ = valueProfileMap.addValue(idx)
    }
    
    func resetMaps() {
        valueProfileMap.reset()
        modules.removeAll()
        clearInlineCounters()
        eightBitCounters.assign(repeating: 0)
        // clear extra and clang counters
    }
    
    func clearInlineCounters() {
        for module in moduleCounters {
            module.assign(repeating: 0)
        }
    }
    
    // record initial stack
    // stack offset
    // for each observed pcs
    // initial stack
    // what is linker-initialized data

    // update feature set is not defined??
    /*
    mutating func addValueForMemcmp(caller: PC, x: UInt8, y: UInt8, n: Int, stopAtZero: Bool) {
        
        guard n != 0 else { return }

        // A: create 64 bytes trivial value
        // B: same as A
        
        // TODO
    }
    */
    // for each non zero byte
}

struct ValueBitMap {
    static let mapSizeInBits: UInt = 1 << 16
    static let mapPrimeMod: UInt = 65371 // Largest Prime < kMapSizeInBits
    static let bitsInWord = UInt(MemoryLayout<UInt>.size * 8)
    static let mapSizeInWords: UInt = ValueBitMap.mapSizeInBits / ValueBitMap.bitsInWord
    
    var map: [UInt] = Array(repeating: 0, count: Int(ValueBitMap.mapSizeInWords))
    
    mutating func reset() {
        for i in map.indices { map[i] = 0 }
    }
    
    // Computes a hash function of Value and sets the corresponding bit.
    // Returns true if the bit was changed from 0 to 1.
    mutating func addValue(_ value: UInt) -> Bool {
        let idx = value % ValueBitMap.mapSizeInBits
        let wordIdx = idx / ValueBitMap.bitsInWord
        let bitIdx = idx % ValueBitMap.bitsInWord
        let old = map[Int(wordIdx)]
        let new = old | (1 << bitIdx)
        map[Int(wordIdx)] = new
        return new != old
    }
    
    mutating func addValueModPrime(_ value: UInt) -> Bool {
        return addValue(value % ValueBitMap.mapPrimeMod)
    }
    
    subscript(idx: UInt) -> Bool {
        precondition(idx < ValueBitMap.mapSizeInBits)
        let wordIdx = idx / ValueBitMap.bitsInWord
        let bitIdx = idx % ValueBitMap.bitsInWord
        return (map[Int(wordIdx)] & (1 << bitIdx)) != 0
    }
    
    var sizeInBits: UInt { return ValueBitMap.mapSizeInBits }
    
    func forEach(_ f: (Int) -> Void) {
        for i in 0 ..< ValueBitMap.mapSizeInWords {
            let M = map[Int(i)]
            guard M != 0 else { continue }
            for j in 0 ..< MemoryLayout<UInt>.size * 8 {
                guard M & (UInt(1) << j) != 0 else { continue }
                f(Int(i) * MemoryLayout<UInt>.size * 8 + j)
            }
            
        }
    }
}

let TPC: TracePC = TracePC.init()







