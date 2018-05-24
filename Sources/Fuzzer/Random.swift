

public struct Rand {
    
    public var seed: UInt32
    
    public init(seed: UInt32) {
        self.seed = seed
    }
    
    mutating func next31() -> UInt32 {
        seed = 214013 &* seed &+ 2531011
        return seed >> 16 &* 0x7FFF
    }
    
    public mutating func bool() -> Bool {
        return (next31() & 0b1) == 0
    }
    
    public mutating func byte() -> UInt8 {
        return UInt8(next31() & 0xFF)
    }
    
    public mutating func int() -> Int {
        let bytes = uint64()
        return Int(bitPattern: UInt(bytes))
    }
    
    public mutating func uint16() -> UInt16 {
        return UInt16(next31() & 0x00FF)
    }
    
    public mutating func uint32() -> UInt32 {
        let l = uint16()
        let r = uint16()
        return (UInt32(l) << 16) | UInt32(r)
    }
    
    public mutating func uint64() -> UInt64 {
        let l = uint32()
        let r = uint32()
        return (UInt64(l) << 32) | UInt64(r)
    }
}

extension Rand {
    public mutating func positiveInt(_ upperBound: Int) -> Int {
        precondition(upperBound != 0, "upperBound must be greater than 0")
        return Int(uint64() % UInt64(upperBound))
    }
    
    public mutating func int(inside: Range<Int>) -> Int {
        return inside.lowerBound + positiveInt(inside.count)
    }
    /*
    public mutating func int(inside: CountableRange<Int>) -> Int {
        return inside.lowerBound + positiveInt(inside.count)
    }*/
    public mutating func pick <C: RandomAccessCollection> (from c: C) -> C.Element where C.Index == Int {
        return c[int(inside: c.startIndex ..< c.endIndex)]
    }
    
    public mutating func weightedPickIndex <T, C: Collection> (from c: C) -> C.Index where C.Element == (T, UInt64), C.Index == Int {
        /* e.g.
        c:
         [5, 2, 10, 1]
        accumulatedWeights:
         [5, 7, 17, 18]
        randWeight:
         (uint64 % 18) + 1 -> uniformly (1...18)
         14
        return:
         [5 < 14, 7 < 14, 17 >= 14, ...]
                            ^ winner
         return c[winner] (10)
         */
        let accumulatedWeights = c.scan(0, { $0 + $1.1 })
        let randWeight = (self.uint64() % accumulatedWeights.last!) + 1
        let i = accumulatedWeights.index(where: { $0 >= randWeight })!
        return i
    }
    public mutating func weightedPick <T, C: Collection> (from c: C) -> T where C.Element == (T, UInt64), C.Index == Int {
        return c[weightedPickIndex(from: c)].0
    }
    
    // TODO: make it lazy
    public mutating func weightedPicks <T, C: Collection> (from c: C) -> [T] where C.Element == (T, UInt64), C.Index == Int {
        var picks: [T] = []
        var accumulatedWeights = c.scan(0, { $0 + $1.1 })
        for _ in 0 ..< c.count {
            let randWeight = (self.uint64() % accumulatedWeights.last!) + 1
            let i = accumulatedWeights.index(where: { $0 >= randWeight })!
            picks.append(c[i].0)
            let weightToRemove = c[i].1
            for j in i ..< accumulatedWeights.endIndex {
                accumulatedWeights[j] -= weightToRemove
            }
        }
        return picks
    }
    
    public mutating func slice <C: RandomAccessCollection> (of c: C, maxLength: Int) -> C.SubSequence where C.Index == Int {
        guard !c.isEmpty else { return c[c.startIndex ..< c.startIndex] }
        let start = int(inside: c.startIndex ..< c.endIndex)
        let end = 1 + int(inside: start ..< min(c.endIndex, start + maxLength))
        assert(start != end)
        return c[start..<end]
    }
    public mutating func prefix <C: RandomAccessCollection> (of c: C, maxLength: Int) -> C.SubSequence where C.Index == Int {
        let end = int(inside: c.startIndex ..< min(c.endIndex, c.startIndex + maxLength + 1))
        return c[..<end]
    }
    public mutating func pick <T> (_ ts: T...) -> T {
        return pick(from: ts)
    }
}

extension Rand {
    mutating func shuffle <C> (_ c: inout C) where C: MutableCollection, C: RandomAccessCollection, C.Indices == CountableRange<Int> {
        for i in (0 ..< c.count).reversed() {
            c.swapAt(int(inside: 0 ..< i+1), i)
        }
    }
}

extension Sequence {
    func scan <T> (_ initial: T, _ acc: (T, Element) -> T) -> [T] {
        var results: [T] = []
        var t = initial
        for x in self {
            t = acc(t, x)
            results.append(t)
        }
        return results
    }
}





