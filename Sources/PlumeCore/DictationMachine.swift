import Foundation

/// Machine d'états du raccourci de dictée :
/// - fn relâché ≥ `minHold` après l'appui = push-to-talk terminé ;
/// - relâché avant : on attend jusqu'à `downAt + doubleTapWindow` un 2ᵉ appui, qui verrouille le mains-libres,
///   sinon la dictée est abandonnée (debounce) ;
/// - fn+espace pendant l'appui = mains-libres ;
/// - en mains-libres, un appui < `doubleTapWindow` après le début = triple-tap → annulation ; au-delà → fin ;
/// - Échap annule ; toute autre touche pressée pendant que fn est maintenu annule, à tout moment
///   (`otherKeyCancelWindow` permet de limiter ça au début de la prise).
/// Pure (horloge injectée) pour être testable ; les effets sont rendus sous forme d'`Action`.
public struct DictationMachine: Equatable {
    public enum State: Equatable {
        case idle
        case pushToTalk(downAt: TimeInterval)
        case tapPending(downAt: TimeInterval)
        case handsFree(startAt: TimeInterval, awaitingRelease: Bool)
        case processing
    }

    public enum Event: Equatable {
        case fnDown(TimeInterval)
        case fnUp(TimeInterval)
        case spaceWhileFn
        /// Clic sur la barre flottante : démarre directement en mains libres.
        case barClick(TimeInterval)
        case otherKeyWhileFn(TimeInterval)
        case escape
        case tapTimeout
        case maxDurationReached
        case processingFinished
    }

    public enum Action: Equatable {
        case startRecording
        case enterHandsFree
        case scheduleTapTimeout(TimeInterval)
        case stopAndProcess
        case cancel
    }

    public var minHold: TimeInterval
    public var doubleTapWindow: TimeInterval
    public var otherKeyCancelWindow: TimeInterval
    public private(set) var state: State = .idle

    public init(minHold: TimeInterval = 0.5, doubleTapWindow: TimeInterval = 0.5, otherKeyCancelWindow: TimeInterval = .infinity) {
        self.minHold = minHold
        self.doubleTapWindow = doubleTapWindow
        self.otherKeyCancelWindow = otherKeyCancelWindow
    }

    public var isRecording: Bool {
        switch state {
        case .pushToTalk, .tapPending, .handsFree: true
        case .idle, .processing: false
        }
    }

    /// Applique un événement ; renvoie les actions à exécuter et si l'événement clavier doit être avalé.
    public mutating func handle(_ event: Event) -> (actions: [Action], swallow: Bool) {
        switch (state, event) {
        case (.idle, .fnDown(let t)):
            state = .pushToTalk(downAt: t)
            return ([.startRecording], true)

        case (.pushToTalk(let downAt), .fnUp(let t)):
            if t - downAt >= minHold {
                state = .processing
                return ([.stopAndProcess], true)
            }
            state = .tapPending(downAt: downAt)
            return ([.scheduleTapTimeout(max(0, downAt + doubleTapWindow - t))], true)

        case (.idle, .barClick(let t)):
            // startAt reculé : le prochain appui sur fn arrête la prise, il n'est pas compté comme triple-tap.
            state = .handsFree(startAt: t - doubleTapWindow, awaitingRelease: false)
            return ([.startRecording, .enterHandsFree], false)

        case (.pushToTalk(let downAt), .spaceWhileFn):
            state = .handsFree(startAt: downAt, awaitingRelease: true)
            return ([.enterHandsFree], true)

        case (.pushToTalk(let downAt), .otherKeyWhileFn(let t)):
            guard t - downAt < otherKeyCancelWindow else { return ([], false) }
            state = .idle
            return ([.cancel], false)

        case (.handsFree(let s, true), .otherKeyWhileFn(let t)):
            guard t - s < otherKeyCancelWindow else { return ([], false) }
            state = .idle
            return ([.cancel], false)

        case (.tapPending(let downAt), .fnDown):
            state = .handsFree(startAt: downAt, awaitingRelease: true)
            return ([.enterHandsFree], true)

        case (.tapPending, .tapTimeout):
            state = .idle
            return ([.cancel], false)

        case (.handsFree(let s, true), .fnUp):
            state = .handsFree(startAt: s, awaitingRelease: false)
            return ([], true)

        case (.handsFree(let s, false), .fnDown(let t)):
            if t - s < doubleTapWindow { // triple-tap
                state = .idle
                return ([.cancel], true)
            }
            state = .processing
            return ([.stopAndProcess], true)

        case (.handsFree, .maxDurationReached), (.pushToTalk, .maxDurationReached):
            state = .processing
            return ([.stopAndProcess], false)

        case (.pushToTalk, .escape), (.tapPending, .escape), (.handsFree, .escape):
            state = .idle
            return ([.cancel], true)

        case (.processing, .processingFinished):
            state = .idle
            return ([], false)

        // fn pendant le traitement ou après un triple-tap : avalé pour ne pas ouvrir le sélecteur d'emoji.
        case (.processing, .fnDown), (.processing, .fnUp), (.handsFree(_, false), .fnUp), (.tapPending, .fnUp), (.idle, .fnUp):
            return ([], true)

        default:
            return ([], false)
        }
    }
}
