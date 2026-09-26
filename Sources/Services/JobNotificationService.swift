import AppKit
import Foundation
import UserNotifications

struct WorkflowRunSummary: Sendable, Equatable {
    let id: Int
    let name: String
    let htmlURL: URL
}

struct WorkflowJobSummary: Sendable, Equatable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let runnerName: String?
    let run: WorkflowRunSummary
}

/// A job a runner picked up while the app was running.
struct RecentJob: Sendable, Equatable, Identifiable {
    var job: WorkflowJobSummary
    var startedAt: Date
    var finishedAt: Date?

    var id: Int { job.id }

    var displayName: String {
        job.run.name.isEmpty ? job.name : "\(job.run.name) · \(job.name)"
    }

    /// "success", "failure", ... once finished; "running" before that.
    var outcome: String {
        finishedAt == nil ? "running" : (job.conclusion ?? "completed")
    }
}

struct JobNotificationPayload: Equatable {
    let title: String
    let body: String
    let runURL: URL
}

enum JobNotificationEvent {
    case started
    case completed
}

enum JobNotificationPayloadFactory {
    static func make(event: JobNotificationEvent, runner: Runner, job: WorkflowJobSummary) -> JobNotificationPayload {
        let workflowName = job.run.name.isEmpty ? job.name : job.run.name

        switch event {
        case .started:
            return JobNotificationPayload(
                title: "Job started on \(runner.name)",
                body: "\(runner.repo) - \(workflowName)",
                runURL: job.run.htmlURL
            )
        case .completed:
            let conclusion = job.conclusion ?? "completed"
            let title = conclusion == "success"
                ? "Job completed on \(runner.name)"
                : "Job failed on \(runner.name)"
            return JobNotificationPayload(
                title: title,
                body: "\(runner.repo) - \(workflowName) (\(conclusion))",
                runURL: job.run.htmlURL
            )
        }
    }
}

@MainActor
final class JobNotificationService: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = JobNotificationService()

    /// nil outside an app bundle (e.g. `swift run`, tests), where
    /// UNUserNotificationCenter raises instead of returning a center.
    private let notificationCenter: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    private var authorizationRequested = false

    func configure() {
        notificationCenter?.delegate = self
        requestAuthorizationIfNeededInternal()
    }

    func notify(event: JobNotificationEvent, runner: Runner, job: WorkflowJobSummary) async {
        guard let notificationCenter else { return }
        requestAuthorizationIfNeeded()

        let payload = JobNotificationPayloadFactory.make(event: event, runner: runner, job: job)
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.userInfo = ["runURL": payload.runURL.absoluteString]

        let request = UNNotificationRequest(
            identifier: "job-\(runner.id.uuidString)-\(job.id)-\(eventIdentifier(for: event))",
            content: content,
            trigger: nil
        )

        notificationCenter.add(request, withCompletionHandler: nil)
    }

    /// Post a general status notification (e.g. runners auto-paused).
    /// Reusing `identifier` replaces the previous notification of that kind.
    func notifyStatus(identifier: String, title: String, body: String) async {
        guard let notificationCenter else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        notificationCenter.add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
            withCompletionHandler: nil
        )
    }

    private func requestAuthorizationIfNeeded() {
        requestAuthorizationIfNeededInternal()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard let rawURL = response.notification.request.content.userInfo["runURL"] as? String,
              let url = URL(string: rawURL) else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func requestAuthorizationIfNeededInternal() {
        guard !authorizationRequested else { return }
        authorizationRequested = true

        notificationCenter?.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    private func eventIdentifier(for event: JobNotificationEvent) -> String {
        switch event {
        case .started:
            return "started"
        case .completed:
            return "completed"
        }
    }
}
