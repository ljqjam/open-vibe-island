import SwiftUI
import OpenIslandCore

// MARK: - Hi IM

struct HiSettingsPane: View {
    var model: AppModel

    @State private var isSendingTest = false
    @State private var testStatus: String?

    private var credentialsFilled: Bool {
        !model.hiAppId.isEmpty && !model.hiAppSecret.isEmpty
            && !model.hiAsnId.isEmpty && !model.hiRecipientAccountId.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Toggle("Hi IM Notifications", isOn: Binding(
                    get: { model.hiNotificationEnabled },
                    set: { model.hiNotificationEnabled = $0 }
                ))

                if model.hiNotificationEnabled {
                    Text("Pushes permission requests, questions, and session completions to your Hi IM account via the Hi OpenAPI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("General")
            }

            if model.hiNotificationEnabled {
                Section("API Credentials") {
                    LabeledContent("App ID") {
                        TextField("appId", text: Binding(
                            get: { model.hiAppId },
                            set: { model.hiAppId = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("App Secret") {
                        SecureField("appSecret", text: Binding(
                            get: { model.hiAppSecret },
                            set: { model.hiAppSecret = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                    }
                }

                Section("Push Target") {
                    LabeledContent("应用号 ID (asnId)") {
                        TextField("asnId", text: Binding(
                            get: { model.hiAsnId },
                            set: { model.hiAsnId = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Recipient Account ID") {
                        TextField("Hi account ID", text: Binding(
                            get: { model.hiRecipientAccountId },
                            set: { model.hiRecipientAccountId = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    Toggle("在 Hi 内审批 (WebSocket)", isOn: Binding(
                        get: { model.hiInteractiveApprovalEnabled },
                        set: { model.hiInteractiveApprovalEnabled = $0 }
                    ))

                    if model.hiInteractiveApprovalEnabled {
                        LabeledContent("卡片模板 ID (可选)") {
                            TextField("schemaId，留空则用文本", text: Binding(
                                get: { model.hiCardSchemaId },
                                set: { model.hiCardSchemaId = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Interactive Approval")
                } footer: {
                    if model.hiInteractiveApprovalEnabled {
                        Text("需在控制台「应用号 AI → 事件订阅」选 WebSocket、订阅 `asn:bot.chat.message:v1` 并发布。之后在 Hi 里回复 y 批准 / n 拒绝（多条待审批时回复: y <短码>）。填了卡片模板 ID 会推送带按钮的卡片，否则用纯文本。多人共用同一机器人时，只有「审批推送的接收人」本人回复才会被采纳，不会互相串。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Button {
                            sendTest()
                        } label: {
                            if isSendingTest {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Send Test Message")
                            }
                        }
                        .disabled(isSendingTest || !credentialsFilled)

                        if let testStatus {
                            Text(testStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("Create an app + robot (应用号) on the Hi open platform to obtain these values, and subscribe the `redcity:asn.asnSendMessageToPerson:v2` API permission.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Credentials are stored in UserDefaults. For higher security, consider moving App Secret to Keychain.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hi IM")
    }

    private func sendTest() {
        isSendingTest = true
        testStatus = nil
        Task {
            let result = await model.sendHiTestMessage()
            testStatus = result
            isSendingTest = false
        }
    }
}
