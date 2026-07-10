import Foundation

public enum OpenClawWatchCommand: String, Codable, Sendable {
    case status = "watch.status"
    case notify = "watch.notify"
}

public enum OpenClawWatchPayloadType: String, Codable, Sendable, Equatable {
    case notify = "watch.notify"
    case reply = "watch.reply"
    case execApprovalPrompt = "watch.execApproval.prompt"
    case execApprovalResolve = "watch.execApproval.resolve"
    case execApprovalResolved = "watch.execApproval.resolved"
    case execApprovalExpired = "watch.execApproval.expired"
    case execApprovalSnapshot = "watch.execApproval.snapshot"
    case execApprovalSnapshotRequest = "watch.execApproval.snapshotRequest"
    // Push-to-talk. The Watch runs on-device STT/TTS and relays plain text:
    // Watch → iPhone (utterance) → gateway session → reply text back to Watch,
    // which speaks it locally. No raw audio crosses the WCSession link.
    case talkUtterance = "watch.talk.utterance"
    case talkState = "watch.talk.state"
    case talkReply = "watch.talk.reply"
}

/// Lifecycle state of a Watch push-to-talk capture, mirrored from the iPhone
/// so the Watch can render "listening / thinking / speaking" without owning the
/// audio pipeline itself.
public enum OpenClawWatchTalkState: String, Codable, Sendable, Equatable {
    case listening
    case transcribing
    case thinking
    case speaking
    case idle
    case error
}

/// Watch → iPhone: the wearer finished a push-to-talk utterance. The Watch has
/// already transcribed the audio on-device; this delivers the final text plus
/// the gateway target (e.g. Spock's session) for the iPhone to relay.
public struct OpenClawWatchTalkUtteranceMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var captureId: String
    public var transcript: String
    public var targetSessionKey: String?
    public var targetLabel: String?
    public var sentAtMs: Int?

    public init(
        captureId: String,
        transcript: String,
        targetSessionKey: String? = nil,
        targetLabel: String? = nil,
        sentAtMs: Int? = nil)
    {
        self.type = .talkUtterance
        self.captureId = captureId
        self.transcript = transcript
        self.targetSessionKey = targetSessionKey
        self.targetLabel = targetLabel
        self.sentAtMs = sentAtMs
    }
}

/// iPhone → Watch: progress updates for an in-flight capture so the wrist UI can
/// reflect thinking / speaking and surface the recognized transcript.
public struct OpenClawWatchTalkStateMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var captureId: String
    public var state: OpenClawWatchTalkState
    public var text: String?
    public var sentAtMs: Int?

    public init(
        captureId: String,
        state: OpenClawWatchTalkState,
        text: String? = nil,
        sentAtMs: Int? = nil)
    {
        self.type = .talkState
        self.captureId = captureId
        self.state = state
        self.text = text
        self.sentAtMs = sentAtMs
    }
}

/// iPhone → Watch: the gateway reply for a capture. `replyText` is spoken on the
/// wrist via the Watch's on-device speech synthesizer; no audio is transferred.
public struct OpenClawWatchTalkReplyMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var captureId: String
    public var transcript: String?
    public var replyText: String
    public var sentAtMs: Int?

    public init(
        captureId: String,
        transcript: String? = nil,
        replyText: String,
        sentAtMs: Int? = nil)
    {
        self.type = .talkReply
        self.captureId = captureId
        self.transcript = transcript
        self.replyText = replyText
        self.sentAtMs = sentAtMs
    }
}

public enum OpenClawWatchRisk: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
}

public enum OpenClawWatchExecApprovalDecision: String, Codable, Sendable, Equatable {
    case allowOnce = "allow-once"
    case deny
}

public enum OpenClawWatchExecApprovalCloseReason: String, Codable, Sendable, Equatable {
    case expired
    case notFound = "not-found"
    case unavailable
    case replaced
    case resolved
}

public struct OpenClawWatchAction: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var style: String?

    public init(id: String, label: String, style: String? = nil) {
        self.id = id
        self.label = label
        self.style = style
    }
}

public struct OpenClawWatchExecApprovalItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var commandText: String
    public var commandPreview: String?
    public var host: String?
    public var nodeId: String?
    public var agentId: String?
    public var expiresAtMs: Int?
    public var allowedDecisions: [OpenClawWatchExecApprovalDecision]
    public var risk: OpenClawWatchRisk?

    public init(
        id: String,
        commandText: String,
        commandPreview: String? = nil,
        host: String? = nil,
        nodeId: String? = nil,
        agentId: String? = nil,
        expiresAtMs: Int? = nil,
        allowedDecisions: [OpenClawWatchExecApprovalDecision] = [],
        risk: OpenClawWatchRisk? = nil)
    {
        self.id = id
        self.commandText = commandText
        self.commandPreview = commandPreview
        self.host = host
        self.nodeId = nodeId
        self.agentId = agentId
        self.expiresAtMs = expiresAtMs
        self.allowedDecisions = allowedDecisions
        self.risk = risk
    }
}

public struct OpenClawWatchExecApprovalPromptMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var approval: OpenClawWatchExecApprovalItem
    public var sentAtMs: Int?
    public var deliveryId: String?
    public var resetResolvingState: Bool?

    public init(
        approval: OpenClawWatchExecApprovalItem,
        sentAtMs: Int? = nil,
        deliveryId: String? = nil,
        resetResolvingState: Bool? = nil)
    {
        self.type = .execApprovalPrompt
        self.approval = approval
        self.sentAtMs = sentAtMs
        self.deliveryId = deliveryId
        self.resetResolvingState = resetResolvingState
    }
}

public struct OpenClawWatchExecApprovalResolveMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var approvalId: String
    public var decision: OpenClawWatchExecApprovalDecision
    public var replyId: String
    public var sentAtMs: Int?

    public init(
        approvalId: String,
        decision: OpenClawWatchExecApprovalDecision,
        replyId: String,
        sentAtMs: Int? = nil)
    {
        self.type = .execApprovalResolve
        self.approvalId = approvalId
        self.decision = decision
        self.replyId = replyId
        self.sentAtMs = sentAtMs
    }
}

public struct OpenClawWatchExecApprovalResolvedMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var approvalId: String
    public var decision: OpenClawWatchExecApprovalDecision?
    public var resolvedAtMs: Int?
    public var source: String?

    public init(
        approvalId: String,
        decision: OpenClawWatchExecApprovalDecision? = nil,
        resolvedAtMs: Int? = nil,
        source: String? = nil)
    {
        self.type = .execApprovalResolved
        self.approvalId = approvalId
        self.decision = decision
        self.resolvedAtMs = resolvedAtMs
        self.source = source
    }
}

public struct OpenClawWatchExecApprovalExpiredMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var approvalId: String
    public var reason: OpenClawWatchExecApprovalCloseReason
    public var expiredAtMs: Int?

    public init(
        approvalId: String,
        reason: OpenClawWatchExecApprovalCloseReason,
        expiredAtMs: Int? = nil)
    {
        self.type = .execApprovalExpired
        self.approvalId = approvalId
        self.reason = reason
        self.expiredAtMs = expiredAtMs
    }
}

public struct OpenClawWatchExecApprovalSnapshotMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var approvals: [OpenClawWatchExecApprovalItem]
    public var sentAtMs: Int?
    public var snapshotId: String?

    public init(
        approvals: [OpenClawWatchExecApprovalItem],
        sentAtMs: Int? = nil,
        snapshotId: String? = nil)
    {
        self.type = .execApprovalSnapshot
        self.approvals = approvals
        self.sentAtMs = sentAtMs
        self.snapshotId = snapshotId
    }
}

public struct OpenClawWatchExecApprovalSnapshotRequestMessage: Codable, Sendable, Equatable {
    public var type: OpenClawWatchPayloadType
    public var requestId: String
    public var sentAtMs: Int?

    public init(requestId: String, sentAtMs: Int? = nil) {
        self.type = .execApprovalSnapshotRequest
        self.requestId = requestId
        self.sentAtMs = sentAtMs
    }
}

public struct OpenClawWatchStatusPayload: Codable, Sendable, Equatable {
    public var supported: Bool
    public var paired: Bool
    public var appInstalled: Bool
    public var reachable: Bool
    public var activationState: String

    public init(
        supported: Bool,
        paired: Bool,
        appInstalled: Bool,
        reachable: Bool,
        activationState: String)
    {
        self.supported = supported
        self.paired = paired
        self.appInstalled = appInstalled
        self.reachable = reachable
        self.activationState = activationState
    }
}

public struct OpenClawWatchNotifyParams: Codable, Sendable, Equatable {
    public var title: String
    public var body: String
    public var priority: OpenClawNotificationPriority?
    public var promptId: String?
    public var sessionKey: String?
    public var kind: String?
    public var details: String?
    public var expiresAtMs: Int?
    public var risk: OpenClawWatchRisk?
    public var actions: [OpenClawWatchAction]?

    public init(
        title: String,
        body: String,
        priority: OpenClawNotificationPriority? = nil,
        promptId: String? = nil,
        sessionKey: String? = nil,
        kind: String? = nil,
        details: String? = nil,
        expiresAtMs: Int? = nil,
        risk: OpenClawWatchRisk? = nil,
        actions: [OpenClawWatchAction]? = nil)
    {
        self.title = title
        self.body = body
        self.priority = priority
        self.promptId = promptId
        self.sessionKey = sessionKey
        self.kind = kind
        self.details = details
        self.expiresAtMs = expiresAtMs
        self.risk = risk
        self.actions = actions
    }
}

public struct OpenClawWatchNotifyPayload: Codable, Sendable, Equatable {
    public var deliveredImmediately: Bool
    public var queuedForDelivery: Bool
    public var transport: String

    public init(deliveredImmediately: Bool, queuedForDelivery: Bool, transport: String) {
        self.deliveredImmediately = deliveredImmediately
        self.queuedForDelivery = queuedForDelivery
        self.transport = transport
    }
}
