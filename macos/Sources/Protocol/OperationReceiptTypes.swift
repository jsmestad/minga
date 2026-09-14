/// Semantic editor target carried by one committed native frame.
public struct PresentationTarget: Sendable, Equatable {
    public let token: UInt64
    public let windowID: UInt16
    public let applicationRevision: UInt32
    public let focusRequired: Bool

    /// Creates a target with its opaque identity, owning window, application revision, and focus requirement.
    public init(token: UInt64, windowID: UInt16, applicationRevision: UInt32, focusRequired: Bool) {
        self.token = token
        self.windowID = windowID
        self.applicationRevision = applicationRevision
        self.focusRequired = focusRequired
    }
}

/// Correlates one admitted BEAM operation with its required native presentation target.
public struct PresentationOperation: Sendable, Equatable {
    public let operationID: UInt64
    public let targetToken: UInt64
    public let windowID: UInt16
    public let applicationRevision: UInt32
    public let focusRequired: Bool

    /// Creates a correlated presentation operation.
    public init(operationID: UInt64, targetToken: UInt64, windowID: UInt16, applicationRevision: UInt32, focusRequired: Bool) {
        self.operationID = operationID
        self.targetToken = targetToken
        self.windowID = windowID
        self.applicationRevision = applicationRevision
        self.focusRequired = focusRequired
    }
}

/// Evidence observed at the strongest native presentation boundary available to Minga.
public struct NativePresentationEvidence: Sendable, Equatable {
    /// Native boundary reached by the correlated frame.
    public enum Boundary: UInt8, Sendable {
        case none = 0
        /// The drawable was scheduled for presentation and its Metal command buffer completed. This does not prove compositor visibility.
        case metalDrawableCompleted = 1
    }

    public let targetToken: UInt64
    public let applicationRevision: UInt32
    public let generation: UInt32
    public let frameSeq: UInt32
    public let windowID: UInt16
    public let focusReady: Bool
    public let boundary: Boundary

    /// Creates native evidence for one target and committed frame.
    public init(targetToken: UInt64, applicationRevision: UInt32, generation: UInt32, frameSeq: UInt32, windowID: UInt16, focusReady: Bool, boundary: Boundary) {
        self.targetToken = targetToken
        self.applicationRevision = applicationRevision
        self.generation = generation
        self.frameSeq = frameSeq
        self.windowID = windowID
        self.focusReady = focusReady
        self.boundary = boundary
    }
}

/// Terminal native result for one correlated presentation operation.
public struct NativeOperationResult: Sendable, Equatable {
    /// Native terminal outcomes that can be proven without compositor visibility claims.
    public enum Outcome: UInt8, Sendable {
        case ready = 0
        case presentationFailed = 1
        case hidden = 2
        case unavailable = 3
        case superseded = 4
    }

    public let operationID: UInt64
    public let targetToken: UInt64
    public let outcome: Outcome
    public let evidence: NativePresentationEvidence
    public let lastVisible: NativePresentationEvidence?

    /// Creates a terminal native result with current and prior visible evidence.
    public init(operationID: UInt64, targetToken: UInt64, outcome: Outcome, evidence: NativePresentationEvidence, lastVisible: NativePresentationEvidence?) {
        self.operationID = operationID
        self.targetToken = targetToken
        self.outcome = outcome
        self.evidence = evidence
        self.lastVisible = lastVisible
    }
}
