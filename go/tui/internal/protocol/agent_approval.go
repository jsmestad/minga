package protocol

// AgentApprovalTarget is the backend-issued identity of one displayed approval.
// It is retained with the transcript message, never derived from the active chat.
type AgentApprovalTarget struct {
	SessionID  string
	RequestID  string
	ToolCallID string
}

func (target AgentApprovalTarget) Valid() bool {
	return len(target.SessionID) > 0 && len(target.SessionID) <= 65535 &&
		len(target.RequestID) > 0 && len(target.RequestID) <= 65535 &&
		len(target.ToolCallID) > 0 && len(target.ToolCallID) <= 65535
}
