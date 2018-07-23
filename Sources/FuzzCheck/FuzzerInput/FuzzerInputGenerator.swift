//
//  FuzzerInputGenerator.swift
//  FuzzCheck
//

/// A protocol defining how to generate, mutate, analyze, and store values of type Input.
public protocol FuzzerInputGenerator: FuzzerInputProperties {
    
    associatedtype Input
    
    /**
     The simplest value of `Input`.
     
     Having a perfect value for `baseInput` is not essential to FuzzCheck.
     
     ## Examples
     - the empty array
     - the number 0
     - an arbitrary value if `Input` doesn't have a “simplest” value
     */
    var baseInput: Input { get }
    
    /**
     Return a new input to test.
     
     It can be completely random or drawn from a corpus of “special” inputs
     or generated in any other way that yields a wide variety of inputs.
    
     - Parameter maxComplexity: the maximum value of the generated input's complexity
     - Parameter rand: a random number generator
     - Returns: The new generated input
     */
    func newInput(maxComplexity: Double, _ rand: inout FuzzerPRNG) -> Input
    
    /**
     Returns an array of initial inputs to fuzz-test.
     
     The elements of the array should be different from each other, and
     each one of them should be interesting in its own way.
     
     For example, one could be an empty array, another one could be a sorted array,
     one a small array and one a large array, etc.
     
     Having a perfect list of initial elements is not essential to FuzzCheck,
     but it can help it start working on the right foot.
     
     - Parameter rand: a random number generator
     */
    func initialInputs(maxComplexity: Double, _ rand: inout FuzzerPRNG) -> [Input]
    
    /**
     Mutate the given input.
     
     FuzzCheck will call this method repeatedly in order to explore all the
     possible values of Input. It is therefore important that it is implemented
     efficiently.
     
     It should be theoretically possible to mutate any arbitrary input `u1` into any
     other arbitrary input `u2` by calling `mutate` repeatedly.
     
     Moreover, the result of `mutate` should try to be “interesting” to FuzzCheck.
     That is, it should be likely to trigger new code paths when passed to the
     test function.
     
     A good approach to implement this method is to use a `FuzzerInputMutatorGroup`.
     
     ## Examples
     - append a random element to an array
     - mutate a random element in an array
     - subtract a small constant from an integer
     - change an integer to Int.min or Int.max or 0
     - replace a substring by a keyword relevant to the test function
     
     - Parameter input: the input to mutate
     - Parameter spareComplexity: the additional complexity that can be added to the input
     - Parameter rand: a random number generator
     - Returns: true iff the input was actually mutated
     */
    func mutate(_ input: inout Input, _ spareComplexity: Double, _ rand: inout FuzzerPRNG) -> Bool
}

extension FuzzerInputGenerator {
    // Default implementation: generate 10 new inputs
    public func initialInputs(maxComplexity: Double, _ r: inout FuzzerPRNG) -> [Input] {
        return (0 ..< 10).map { _ in
            newInput(maxComplexity: maxComplexity, &r)
        }
    }
}

/**
 A type providing a list of weighted mutators, which is handy to implement
 the `mutate` method of a `FuzzerInputGenerator`.
 
 The weight of a mutator determines how often it should be used relative to
 the other mutators in the list.
 */
public protocol FuzzerInputMutatorGroup {
    associatedtype Input
    associatedtype Mutator
    
    /**
     Mutate the given input using the given mutator and random number generator.
     
     - Parameter input: the input to mutate
     - Parameter mutator: the mutator to use to mutate the input
     - Parameter rand: a random number generator
     - Returns: true iff the input was actually mutated
     */
    func mutate(_ input: inout Input, with mutator: Mutator, spareComplexity: Double,  _ rand: inout FuzzerPRNG) -> Bool
    
    /**
     A list of mutators and their associated weight.
     
     # IMPORTANT
     The second component of the tuples in the array is the sum of the previous weight
     and the weight of the mutator itself. For example, for three mutators `(m1, m2, m3)`
     with relative weights `(120, 5, 56)`. Then `weightedMutators` should return
     `[(m1, 120), (m2, 125), (m3, 181)]`.
     */
    var weightedMutators: [(Mutator, UInt)] { get }
}

extension FuzzerInputMutatorGroup {
    /**
     Choose a mutator from the list of weighted mutators and execute it on `input`.
     
     - Parameter input: the input to mutate
     - Parameter mutator: the mutator to use to mutate the input
     - Parameter rand: a random number generator
     - Returns: true iff the input was actually mutated
     */
    public func mutate(_ input: inout Input, _ spareComplexity: Double, _ rand: inout FuzzerPRNG) -> Bool {
        for _ in 0 ..< weightedMutators.count {
            let mutator = rand.weightedRandomElement(from: weightedMutators, minimum: 0)
            if mutate(&input, with: mutator, spareComplexity: spareComplexity, &rand) { return true }
        }
        return false
    }
}

