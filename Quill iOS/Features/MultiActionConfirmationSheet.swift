import Combine
import HexCore
import SwiftUI

@MainActor
final class MultiActionConfirmationViewModel: ObservableObject {
  @Published var rawTranscript: String = ""
  @Published var items: [ActionItemVM] = []
  @Published var isExecuting: Bool = false
  @Published var completion: Completion?

  struct ActionItemVM: Identifiable {
    let id = UUID()
    var intent: ActionIntent
    var editableTitle: String
    var editableDueDate: String
    var editableNotes: String
    var editableRecipient: String
    var editableSubject: String
    var editableBody: String
    var isExpanded: Bool = false

    init(intent: ActionIntent) {
      self.intent = intent
      self.editableTitle = intent.title
      self.editableDueDate = intent.dueDate ?? ""
      self.editableNotes = intent.notes ?? ""
      self.editableRecipient = intent.recipient ?? ""
      self.editableSubject = intent.subject ?? intent.title
      self.editableBody = intent.notes ?? ""
    }

    var displayTitle: String {
      if intent.targetIntegration == .gmail, !editableSubject.isEmpty {
        return editableSubject
      }
      return editableTitle.isEmpty ? "(untitled)" : editableTitle
    }

    var displaySubtitle: String {
      switch intent.targetIntegration {
      case .calendar, .googleCalendar:
        return editableDueDate.isEmpty ? "No time" : editableDueDate
      case .gmail:
        return editableRecipient.isEmpty ? "Draft" : "To: \(editableRecipient)"
      default:
        return editableDueDate.isEmpty ? "No date" : editableDueDate
      }
    }

    func buildFinalIntent() -> ActionIntent {
      var final = intent
      final.title = editableTitle
      final.dueDate = editableDueDate.isEmpty ? nil : editableDueDate
      final.notes = editableNotes.isEmpty ? nil : editableNotes
      if intent.targetIntegration == .gmail {
        final.actionType = .createDraft
        final.recipient = editableRecipient.isEmpty ? nil : editableRecipient
        final.subject = editableSubject.isEmpty ? nil : editableSubject
        final.notes = editableBody.isEmpty ? nil : editableBody
      }
      return final
    }
  }

  struct Completion: Equatable {
    let succeeded: Int
    let failed: Int
    let queued: Int
  }

  init() {}

  func applyParsedIntents(_ intents: [ActionIntent], rawTranscript: String) {
    self.rawTranscript = rawTranscript
    self.items = intents.map { ActionItemVM(intent: $0) }
    self.completion = nil
    self.isExecuting = false
  }

  func removeItem(at id: UUID) {
    items.removeAll { $0.id == id }
  }

  func executeAll() async {
    isExecuting = true
    var succeeded = 0
    var failed = 0
    var queued = 0

    let executor = IOSSystemActionQueueExecutor()
    for item in items {
      let finalIntent = item.buildFinalIntent()
      do {
        try await executor.execute(finalIntent)
        succeeded += 1
      } catch {
        if QueueableErrorClassifier.isQueueable(error) {
          await ActionQueueManager.shared.enqueue(finalIntent, lastError: error.localizedDescription)
          queued += 1
        } else {
          failed += 1
        }
      }
    }

    isExecuting = false
    completion = Completion(succeeded: succeeded, failed: failed, queued: queued)
  }

}

struct MultiActionConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var vm: MultiActionConfirmationViewModel

  var body: some View {
    ZStack {
      panelBackground.ignoresSafeArea()

      if let completion = vm.completion {
        multiCompletionView(completion)
          .transition(.scale(scale: 0.92).combined(with: .opacity))
          .task(id: completion) {
            if completion.failed == 0 {
              UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
              UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            if completion.queued > 0 {
              NotificationCenter.default.post(name: .quillActionQueuedOffline, object: nil)
            }
            try? await Task.sleep(for: .milliseconds(1800))
            dismiss()
          }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            header
            heardSection
            willDoSection
            footer
          }
          .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
      }
    }
    .animation(.spring(duration: 0.35, bounce: 0.18), value: vm.completion)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(.clear)
  }

  // MARK: - Background

  private var panelBackground: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      Rectangle().fill(colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.65))
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.purple.opacity(0.2))
          .frame(width: 36, height: 36)
        Image(systemName: "bolt.horizontal.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.purple)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("\(vm.items.count) actions detected")
          .font(.system(size: 15, weight: .semibold))
        Text("Multi-action mode")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  // MARK: - HEARD

  @ViewBuilder
  private var heardSection: some View {
    if !vm.rawTranscript.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("HEARD")
          .font(.system(size: 10, weight: .semibold))
          .tracking(1.4)
          .foregroundStyle(.secondary)
        Text("\u{201C}\(vm.rawTranscript)\u{201D}")
          .font(.system(size: 14))
          .lineLimit(3)
      }
    }
  }

  // MARK: - WILL DO

  private var willDoSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("WILL DO")
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.4)
        .foregroundStyle(.secondary)

      ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
        actionCard(item, index: index)
      }
    }
  }

  private func actionCard(_ item: MultiActionConfirmationViewModel.ActionItemVM, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        integrationTile(item.intent.targetIntegration)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.displayTitle)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
          Text(item.displaySubtitle)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          withAnimation { vm.items[index].isExpanded.toggle() }
        } label: {
          Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
        }
        Button {
          withAnimation { vm.removeItem(at: item.id) }
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)

      if item.isExpanded {
        Divider()
        expandedFields(index: index)
          .padding(.vertical, 6)
          .padding(.horizontal, 12)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private func expandedFields(index: Int) -> some View {
    let item = vm.items[index]
    VStack(spacing: 8) {
      if item.intent.targetIntegration == .gmail {
        HStack {
          Text("To")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .leading)
          TextField("Recipient", text: $vm.items[index].editableRecipient)
            .font(.system(size: 13))
        }
        HStack {
          Text("Subject")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .leading)
          TextField("Subject", text: $vm.items[index].editableSubject)
            .font(.system(size: 13))
        }
      } else {
        HStack {
          Text("Title")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .leading)
          TextField("Title", text: $vm.items[index].editableTitle)
            .font(.system(size: 13))
        }
        HStack {
          Text("Due")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .leading)
          TextField("e.g. Friday", text: $vm.items[index].editableDueDate)
            .font(.system(size: 13))
        }
      }
      HStack {
        Text("Notes")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(width: 50, alignment: .leading)
        TextField("Optional", text: $vm.items[index].editableNotes)
          .font(.system(size: 13))
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Button { dismiss() } label: {
        Text("Dismiss")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
      }

      Button {
        Task { await vm.executeAll() }
      } label: {
        HStack(spacing: 6) {
          if vm.isExecuting {
            ProgressView().tint(.white)
          }
          Text("Run \(vm.items.count) actions")
            .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(vm.isExecuting ? Color.purple.opacity(0.5) : Color.purple)
        )
      }
      .disabled(vm.isExecuting || vm.items.isEmpty)
    }
  }

  // MARK: - Completion

  private func multiCompletionView(_ c: MultiActionConfirmationViewModel.Completion) -> some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill((c.failed == 0 ? Color.green : Color.orange).opacity(0.2))
          .frame(width: 72, height: 72)
        Circle()
          .fill(c.failed == 0 ? Color.green : Color.orange)
          .frame(width: 52, height: 52)
        Image(systemName: c.failed == 0 ? "checkmark" : "exclamationmark.triangle")
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(.white)
      }
      VStack(spacing: 4) {
        Text(c.failed == 0 ? "Done" : "Partial success")
          .font(.system(size: 16, weight: .semibold))
        Text(completionSubhead(c))
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func completionSubhead(_ c: MultiActionConfirmationViewModel.Completion) -> String {
    var parts: [String] = []
    if c.succeeded > 0 { parts.append("\(c.succeeded) created") }
    if c.queued > 0 { parts.append("\(c.queued) queued offline") }
    if c.failed > 0 { parts.append("\(c.failed) failed") }
    return parts.joined(separator: ", ")
  }

  // MARK: - Helpers

  private func integrationTile(_ id: Integration.Identifier) -> some View {
    let icon = Integration.all.first { $0.identifier == id }?.systemImage ?? "questionmark.circle"
    let hex = Integration.all.first { $0.identifier == id }?.tintHex ?? ""
    return RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(Color(hex: hex) ?? .orange)
      .frame(width: 28, height: 28)
      .overlay(
        Image(systemName: icon)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
      )
  }
}
