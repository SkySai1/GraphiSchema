import Foundation

@MainActor
enum ProjectRemoval {
    static let notification = Notification.Name("GraphiSchema.projectRemoved")

    static func post(_ projectID: String) {
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["projectId": projectID])
    }
}
