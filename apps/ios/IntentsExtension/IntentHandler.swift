import Intents

final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        if intent is INStartCallIntent {
            return WADStartCallIntentHandler()
        }
        return self
    }
}

final class WADStartCallIntentHandler: NSObject, INStartCallIntentHandling {
    func confirm(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        completion(INStartCallIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        let activity = NSUserActivity(activityType: "it.differen.openclaw.start-call")
        activity.title = "WAD Start Call"
        if let person = intent.contacts?.first {
            activity.userInfo = [
                "displayName": person.displayName,
                "handle": person.personHandle?.value ?? "",
            ]
        }
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }

    func resolveContacts(
        for intent: INStartCallIntent,
        with completion: @escaping ([INStartCallContactResolutionResult]) -> Void)
    {
        let contacts = intent.contacts ?? []
        guard !contacts.isEmpty else {
            completion([.needsValue()])
            return
        }
        completion(contacts.map { .success(with: $0) })
    }

    func resolveDestinationType(
        for intent: INStartCallIntent,
        with completion: @escaping (INCallDestinationTypeResolutionResult) -> Void)
    {
        completion(.success(with: .normal))
    }

    func resolveCallCapability(
        for intent: INStartCallIntent,
        with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void)
    {
        completion(INStartCallCallCapabilityResolutionResult.success(with: .audioCall))
    }
}
