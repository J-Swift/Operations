//
//  Operation.swift
//  YapDB
//
//  Created by Daniel Thorpe on 25/06/2015.
//  Copyright (c) 2015 Daniel Thorpe. All rights reserved.
//

// swiftlint:disable file_length

import Foundation

// swiftlint:disable type_body_length

/**
Abstract base Operation class which subclasses `NSOperation`.

Operation builds on `NSOperation` in a few simple ways.

1. For an instance to become `.Ready`, all of its attached
`OperationCondition`s must be satisfied.

2. It is possible to attach `OperationObserver`s to an instance,
to be notified of lifecycle events in the operation.

*/
public class Operation: NSOperation {

    private enum State: Int, Comparable {

        // The initial state
        case Initialized

        // Ready to begin evaluating conditions
        case Pending

        // It is executing
        case Executing

        // Execution has completed, but not yet notified queue
        case Finishing

        // The operation has finished.
        case Finished

        func canTransitionToState(other: State, whenCancelled cancelled: Bool) -> Bool {
            switch (self, other) {
            case (.Initialized, .Pending),
                (.Pending, .Executing),
                (.Executing, .Finishing),
                (.Finishing, .Finished):
                return true

            case (.Pending, .Finishing) where cancelled:
                // When an operation is cancelled it can go from pending direct to finishing.
                return true

            default:
                return false
            }
        }
    }

    /**
     Type to express the intent of the user in regards to executing an Operation instance

     - see: https://developer.apple.com/library/ios/documentation/Performance/Conceptual/EnergyGuide-iOS/PrioritizeWorkWithQoS.html#//apple_ref/doc/uid/TP40015243-CH39
    */
    public enum UserIntent: Int {
        case None = 0, SideEffect, Initiated

        internal var qos: NSQualityOfService {
            switch self {
            case .Initiated, .SideEffect:
                return .UserInitiated
            default:
                return .Default
            }
        }
    }

    class func keyPathsForValuesAffectingIsExecuting() -> Set<NSObject> {
        return ["State"]
    }

    class func keyPathsForValuesAffectingIsFinished() -> Set<NSObject> {
        return ["State"]
    }

    class func keyPathsForValuesAffectingIsCancelled() -> Set<NSObject> {
        return ["Cancelled"]
    }

    /// - returns: a unique String which can be used to identify the operation instance
    public let identifier = NSUUID().UUIDString

    private let stateLock = NSLock()
    private lazy var _log: LoggerType = Logger()
    private var _state = State.Initialized
    private var _internalErrors = [ErrorType]()
    private var _hasFinishedAlready = false
    private var _observers = Protector([OperationObserverType]())

    internal private(set) var directDependencies = Set<NSOperation>()
    internal private(set) var conditions = Set<Condition>()

    internal var indirectDependencies: Set<NSOperation> {
        return Set(conditions.flatMap { $0.directDependencies })
    }

    // Internal operation properties which are used to manage the scheduling of dependencies
    internal private(set) var evaluateConditionsOperation: GroupOperation? = .None

    private var _cancelled = false {
        willSet {
            willChangeValueForKey("Cancelled")
            if !_cancelled && newValue {
                operationWillCancel(errors)
                willCancelObservers.forEach { $0.willCancelOperation(self, errors: self.errors) }
            }
        }
        didSet {
            didChangeValueForKey("Cancelled")

            if _cancelled && !oldValue {
                operationDidCancel()
                didCancelObservers.forEach { $0.didCancelOperation(self) }
            }
        }
    }

    /// Access the internal errors collected by the Operation
    public var errors: [ErrorType] {
        return _internalErrors
    }

    /**
     Expresses the user intent in regards to the execution of this Operation.

     Setting this property will set the appropriate quality of service parameter
     on the Operation.

     - requires: self must not have started yet. i.e. either hasn't been added
     to a queue, or is waiting on dependencies.
     */
    public var userIntent: UserIntent = .None {
        didSet {
            setQualityOfServiceFromUserIntent(userIntent)
        }
    }

    /**
     Modifies the quality of service of the underlying operation.

     - requires: self must not have started yet. i.e. either hasn't been added
     to a queue, or is waiting on dependencies.

     - returns: a Bool indicating whether or not the quality of service is .UserInitiated
    */
    @available(*, unavailable, message="This property has been deprecated in favor of userIntent.")
    public var userInitiated: Bool {
        get {
            return qualityOfService == .UserInitiated
        }
        set {
            precondition(state < .Executing, "Cannot modify userInitiated after execution has begun.")
            qualityOfService = newValue ? .UserInitiated : .Default
        }
    }

    /**
     # Access the logger for this Operation
     The `log` property can be used as the interface to access the logger.
     e.g. to output a message with `LogSeverity.Info` from inside
     the `Operation`, do this:

    ```swift
    log.info("This is my message")
    ```

     To adjust the instance severity of the LoggerType for the
     `Operation`, access it via this property too:

    ```swift
    log.severity = .Verbose
    ```

     The logger is a very simple type, and all it does beyond
     manage the enabled status and severity is send the String to
     a block on a dedicated serial queue. Therefore to provide custom
     logging, set the `logger` property:

     ```swift
     log.logger = { message in sendMessageToAnalytics(message) }
     ```

     By default, the Logger's logger block is the same as the global
     LogManager. Therefore to use a custom logger for all Operations:

     ```swift
     LogManager.logger = { message in sendMessageToAnalytics(message) }
     ```

    */
    public var log: LoggerType {
        get {
            _log.operationName = operationName
            return _log
        }
        set {
            _log = newValue
        }
    }

    /**
     Add a condition to the to the operation, can only be done prior to the operation starting.

     - requires: self must not have started yet. i.e. either hasn't been added
     to a queue, or is waiting on dependencies.
     - parameter condition: type conforming to protocol `OperationCondition`.
     */
    @available(iOS, deprecated=8, message="Refactor OperationCondition types as Condition subclasses.")
    @available(OSX, deprecated=10.10, message="Refactor OperationCondition types as Condition subclasses.")
    public func addCondition(condition: OperationCondition) {
        assert(state < .Executing, "Cannot modify conditions after operation has begun executing, current state: \(state).")
        let operation = WrappedOperationCondition(condition)
        if let dependency = condition.dependencyForOperation(self) {
            operation.addDependency(dependency)
        }
        conditions.insert(operation)
    }

    public func addCondition(condition: Condition) {
        assert(state < .Executing, "Cannot modify conditions after operation has begun executing, current state: \(state).")
        conditions.insert(condition)
    }

    /**
     Add an observer to the to the operation, can only be done
     prior to the operation starting.

     - requires: self must not have started yet. i.e. either hasn't been added
     to a queue, or is waiting on dependencies.
     - parameter observer: type conforming to protocol `OperationObserverType`.
     */
    public func addObserver(observer: OperationObserverType) {

        observers.append(observer)

        observer.didAttachToOperation(self)
    }

    /**
     Subclasses should override this method to perform their specialized task.
     They must call a finish methods in order to complete.
     */
    public func execute() {
        print("\(self.dynamicType) must override `execute()`.", terminator: "")
        finish()
    }

    /**
     Subclasses may override `finished(_:)` if they wish to react to the operation
     finishing with errors.

     - parameter errors: an array of `ErrorType`.
     */
    @available(*, unavailable, renamed="operationDidFinish")
    public func finished(errors: [ErrorType]) {
        operationDidFinish(errors)
    }

    /**
     Subclasses may override `operationWillFinish(_:)` if they wish to
     react to the operation finishing with errors.

     - parameter errors: an array of `ErrorType`.
     */
    public func operationWillFinish(errors: [ErrorType]) { /* No op */ }

    /**
     Subclasses may override `operationDidFinish(_:)` if they wish to
     react to the operation finishing with errors.

     - parameter errors: an array of `ErrorType`.
     */
    public func operationDidFinish(errors: [ErrorType]) { /* no op */ }

    // MARK: - Cancellation

    /**
     Cancel the operation with an error.

     - parameter error: an optional `ErrorType`.
     */
    public func cancelWithError(error: ErrorType? = .None) {
        cancelWithErrors(error.map { [$0] } ?? [])
    }

    /**
     Cancel the operation with multiple errors.

     - parameter errors: an `[ErrorType]` defaults to empty array.
     */
    public func cancelWithErrors(errors: [ErrorType] = []) {
        if !errors.isEmpty {
            log.warning("Did cancel with errors: \(errors).")
        }
        _internalErrors += errors
        cancel()
    }

    /**
     Subclasses may override `operationWillCancel(_:)` if they wish to
     react to the operation finishing with errors.

     - parameter errors: an array of `ErrorType`.
     */
    public func operationWillCancel(errors: [ErrorType]) { /* No op */ }

    /**
     Subclasses may override `operationDidCancel(_:)` if they wish to
     react to the operation finishing with errors.

     - parameter errors: an array of `ErrorType`.
     */
    public func operationDidCancel() { /* No op */ }

    public override func cancel() {
        if !finished {
            _cancelled = true
            log.verbose("Did cancel.")
            if executing {
                super.cancel()
                finish()
            }
        }
    }
}

// swiftlint:enable type_body_length

// MARK: - State

public extension Operation {

    private var state: State {
        get {
            return stateLock.withCriticalScope { _state }
        }
        set (newState) {
            willChangeValueForKey("State")
            stateLock.withCriticalScope {
                assert(_state.canTransitionToState(newState, whenCancelled: cancelled), "Attempting to perform illegal cyclic state transition, \(_state) -> \(newState) for operation: \(identity).")
                log.verbose("\(_state) -> \(newState)")
                _state = newState
            }
            didChangeValueForKey("State")
        }
    }

    /// Boolean indicator for whether the Operation is currently executing or not
    final override var executing: Bool {
        return state == .Executing
    }

    /// Boolean indicator for whether the Operation has finished or not
    final override var finished: Bool {
        return state == .Finished
    }

    /// Boolean indicator for whether the Operation has cancelled or not
    final override var cancelled: Bool {
        return _cancelled
    }

    /// Boolean flag to indicate that the Operation failed due to errors.
    var failed: Bool {
        return errors.count > 0
    }

    internal func willEnqueue() {
        state = .Pending
    }
}

// MARK: - Dependencies

public extension Operation {

    internal func evaluateConditions() -> GroupOperation {

        func createEvaluateConditionsOperation() -> GroupOperation {
            // Set the operation on each condition
            conditions.forEach { $0.operation = self }

            let evaluator = GroupOperation(operations: Array(conditions))
            evaluator.name = "Condition Evaluator for: \(operationName)"
            super.addDependency(evaluator)
            return evaluator
        }

        assert(state <= .Executing, "Dependencies cannot be modified after execution has begun, current state: \(state).")

        let evaluator = createEvaluateConditionsOperation()

        // Add an observer to the evaluator to see if any of the conditions failed.
        evaluator.addObserver(WillFinishObserver { [unowned self] operation, errors in
            if errors.count > 0 {
                // If conditions fail, we should cancel the operation
                self.cancelWithErrors(errors)
            }
        })

        directDependencies.forEach {
            evaluator.addDependency($0)
        }

        return evaluator
    }

    internal func addDependencyOnPreviousMutuallyExclusiveOperation(operation: Operation) {
        precondition(state <= .Executing, "Dependencies cannot be modified after execution has begun, current state: \(state).")
        super.addDependency(operation)
    }

    internal func addDirectDependency(directDependency: NSOperation) {
        precondition(state <= .Executing, "Dependencies cannot be modified after execution has begun, current state: \(state).")
        directDependencies.insert(directDependency)
        super.addDependency(directDependency)
    }

    internal func removeDirectDependency(directDependency: NSOperation) {
        precondition(state <= .Executing, "Dependencies cannot be modified after execution has begun, current state: \(state).")
        directDependencies.remove(directDependency)
        super.removeDependency(directDependency)
    }

    /// Public override to get the dependencies
    final override var dependencies: [NSOperation] {
        return Array(directDependencies.union(indirectDependencies))
    }

    /**
     Add another `NSOperation` as a dependency. It is a programmatic error to call
     this method after the receiver has already started executing. Therefore, best
     practice is to add dependencies before adding them to operation queues.

     - requires: self must not have started yet. i.e. either hasn't been added
     to a queue, or is waiting on dependencies.
     - parameter operation: a `NSOperation` instance.
     */
    final override func addDependency(operation: NSOperation) {
        precondition(state <= .Executing, "Dependencies cannot be modified after execution has begun, current state: \(state).")
        addDirectDependency(operation)
    }

    /**
     Remove another `NSOperation` as a dependency. It is a programmatic error to call
     this method after the receiver has already started executing. Therefore, best
     practice is to manage dependencies before adding them to operation
     queues.

     - requires: self must not have started yet. i.e. either hasn't been added
     to a queue, or is waiting on dependencies.
     - parameter operation: a `NSOperation` instance.
     */
    final override func removeDependency(operation: NSOperation) {
        precondition(state <= .Executing, "Dependencies cannot be modified after execution has begun, current state: \(state).")
        removeDirectDependency(operation)
    }
}

// MARK: - Observers

public extension Operation {

    private(set) var observers: [OperationObserverType] {
        get {
            return _observers.read { $0 }
        }
        set {
            _observers.write { (inout ward: [OperationObserverType]) in
                ward = newValue
            }
        }
    }

    internal var willExecuteObservers: [OperationWillExecuteObserver] {
        return observers.flatMap { $0 as? OperationWillExecuteObserver }
    }

    internal var willCancelObservers: [OperationWillCancelObserver] {
        return observers.flatMap { $0 as? OperationWillCancelObserver }
    }

    internal var didCancelObservers: [OperationDidCancelObserver] {
        return observers.flatMap { $0 as? OperationDidCancelObserver }
    }

    internal var didProduceOperationObservers: [OperationDidProduceOperationObserver] {
        return observers.flatMap { $0 as? OperationDidProduceOperationObserver }
    }

    internal var willFinishObservers: [OperationWillFinishObserver] {
        return observers.flatMap { $0 as? OperationWillFinishObserver }
    }

    internal var didFinishObservers: [OperationDidFinishObserver] {
        return observers.flatMap { $0 as? OperationDidFinishObserver }
    }
}

// MARK: - Execution

public extension Operation {

    /// Starts the operation, correctly managing the cancelled state. Cannot be over-ridden
    final override func start() {
        // Don't call super.start

        guard !cancelled else {
            finish()
            return
        }

        main()
    }

    /// Triggers execution of the operation's task, correctly managing errors and the cancelled state. Cannot be over-ridden
    final override func main() {

        guard _internalErrors.isEmpty && !cancelled else {
            finish()
            return
        }

        willExecuteObservers.forEach { $0.willExecuteOperation(self) }
        state = .Executing
        log.verbose("Will Execute")
        execute()
    }

    /**
     Produce another operation on the same queue that this instance is on.

     - parameter operation: a `NSOperation` instance.
     */
    final func produceOperation(operation: NSOperation) {
        precondition(state > .Initialized, "Cannot produce operation while not being scheduled on a queue.")
        log.verbose("Did produce \(operation.operationName)")
        didProduceOperationObservers.forEach { $0.operation(self, didProduceOperation: operation) }
    }
}

// MARK: - Finishing

public extension Operation {

    /**
     Finish method which must be called eventually after an operation has
     begun executing, unless it is cancelled.

     - parameter errors: an array of `ErrorType`, which defaults to empty.
     */
    final func finish(receivedErrors: [ErrorType] = []) {
        if !_hasFinishedAlready {
            _hasFinishedAlready = true
            state = .Finishing

            _internalErrors.appendContentsOf(receivedErrors)
            operationDidFinish(_internalErrors)

            if errors.isEmpty {
                log.verbose("Will finish with no errors.")
            }
            else {
                log.warning("Will finish with \(errors.count) errors.")
            }

            willFinishObservers.forEach { $0.willFinishOperation(self, errors: self._internalErrors) }

            state = .Finished

            didFinishObservers.forEach { $0.didFinishOperation(self, errors: self._internalErrors) }

            if errors.isEmpty {
                log.verbose("Did finish with no errors.")
            }
            else {
                log.warning("Did finish with errors: \(errors).")
            }
        }
    }

    /// Convenience method to simplify finishing when there is only one error.
    final func finish(receivedError: ErrorType?) {
        finish(receivedError.map { [$0]} ?? [])
    }

    /**
     Public override which deliberately crashes your app, as usage is considered an antipattern

     To promote best practices, where waiting is never the correct thing to do,
     we will crash the app if this is called. Instead use discrete operations and
     dependencies, or groups, or semaphores or even NSLocking.

     */
    final override func waitUntilFinished() {
        fatalError("Waiting on operations is an anti-pattern. Remove this ONLY if you're absolutely sure there is No Other Way™. Post a question in https://github.com/danthorpe/Operations if you are unsure.")
    }
}

private func < (lhs: Operation.State, rhs: Operation.State) -> Bool {
    return lhs.rawValue < rhs.rawValue
}

private func == (lhs: Operation.State, rhs: Operation.State) -> Bool {
    return lhs.rawValue == rhs.rawValue
}

/**
A common error type for Operations. Primarily used to indicate error when
an Operation's conditions fail.
*/
public enum OperationError: ErrorType, Equatable {

    /// Indicates that a condition of the Operation failed.
    case ConditionFailed

    /// Indicates that the operation timed out.
    case OperationTimedOut(NSTimeInterval)

    /// Indicates that a parent operation was cancelled (with errors).
    case ParentOperationCancelledWithErrors([ErrorType])
}

/// OperationError is Equatable.
public func == (lhs: OperationError, rhs: OperationError) -> Bool {
    switch (lhs, rhs) {
    case (.ConditionFailed, .ConditionFailed):
        return true
    case let (.OperationTimedOut(aTimeout), .OperationTimedOut(bTimeout)):
        return aTimeout == bTimeout
    case let (.ParentOperationCancelledWithErrors(aErrors), .ParentOperationCancelledWithErrors(bErrors)):
        // Not possible to do a real equality check here.
        return aErrors.count == bErrors.count
    default:
        return false
    }
}

extension NSOperation {

    /**
    Chain completion blocks.

    - parameter block: a Void -> Void block
    */
    public func addCompletionBlock(block: Void -> Void) {
        if let existing = completionBlock {
            completionBlock = {
                existing()
                block()
            }
        }
        else {
            completionBlock = block
        }
    }

    /**
    Add multiple depdendencies to the operation. Will add each
    dependency in turn.

    - parameter dependencies: and array of `NSOperation` instances.
    */
    public func addDependencies<S where S: SequenceType, S.Generator.Element: NSOperation>(dependencies: S) {
        precondition(!executing && !finished, "Cannot modify the dependencies after the operation has started executing.")
        dependencies.forEach(addDependency)
    }

    /**
     Remove multiple depdendencies from the operation. Will remove each
     dependency in turn.

     - parameter dependencies: and array of `NSOperation` instances.
     */
    public func removeDependencies<S where S: SequenceType, S.Generator.Element: NSOperation>(dependencies: S) {
        precondition(!executing && !finished, "Cannot modify the dependencies after the operation has started executing.")
        dependencies.forEach(removeDependency)
    }

    /// Removes all the depdendencies from the operation.
    public func removeDependencies() {
        removeDependencies(dependencies)
    }

    internal func setQualityOfServiceFromUserIntent(userIntent: Operation.UserIntent) {
        qualityOfService = userIntent.qos
    }
}

extension NSLock {
    func withCriticalScope<T>(@noescape block: () -> T) -> T {
        lock()
        let value = block()
        unlock()
        return value
    }
}

extension NSRecursiveLock {
    func withCriticalScope<T>(@noescape block: () -> T) -> T {
        lock()
        let value = block()
        unlock()
        return value
    }
}

extension Array where Element: NSOperation {

    internal var splitNSOperationsAndOperations: ([NSOperation], [Operation]) {
        return reduce(([], [])) { result, element in
            var (ns, op) = result
            if let operation = element as? Operation {
                op.append(operation)
            }
            else {
                ns.append(element)
            }
            return (ns, op)
        }
    }

    internal var userIntent: Operation.UserIntent {
        get {
            let (_, ops) = splitNSOperationsAndOperations
            return ops.map { $0.userIntent }.maxElement { $0.rawValue < $1.rawValue } ?? .None
        }
    }

    internal func forEachOperation(@noescape body: (Operation) throws -> Void) rethrows {
        try forEach {
            if let operation = $0 as? Operation {
                try body(operation)
            }
        }
    }
}

// swiftlint:enable file_length
