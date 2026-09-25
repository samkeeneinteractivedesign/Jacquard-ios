import SwiftUI
import Observation

// The three pages a first launch opens on, and the grey laid over everything but the
// control the page is about. Ported from Assets/Jacquard/App/Onboarding.cs and
// Assets/Jacquard/UI/OnboardingPanel.cs and OnboardingShade.cs.
//
// The pages are up on every launch until "Don't show this again" is ticked, which is the
// only thing on the panel that is remembered; Done closes them for the launch it is
// pressed on. They do not come up with Stage Mode on, and go down if it is switched on.
//
// The sheet is one flat grey at one alpha with a hole cut in it: a vertical slot through
// the transport row around the page's subject, with a light in it that swells while the
// page is read. Nothing in it is picked, so the row and the plane behind it still work,
// and Play works through it. It fades in half a second after launch, and the panel is
// raised only once the screen has finished going under.
//
// Features.onboarding switches all of it off.

enum OnboardingSetting {
    static let key = "Jacquard.Onboarding"

    static var dismissed: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    // Whether this launch opens on the pages at all.
    static var wanted: Bool {
        Features.onboarding && !dismissed && !StageMode.on &&
        !ProcessInfo.processInfo.arguments.contains("-skipOnboarding")
    }
}

// Where the page's subject stands, as reported by the transport row, and how far the
// shade has come down.
@Observable
final class OnboardingState {
    static let pages: [(header: String, body: String, picture: String)] = [
        ("Play",
         "Play starts the sequence and stops it again. The bar beside it is the tempo — " +
         "drag it, or double tap to type a number.",
         "Onboarding-1-play"),
        ("Scores",
         "The arrows at the right of the row pick one of the saved scores, Load opens it " +
         "and Save writes the piece back to it. Drag the row sideways if it runs off the " +
         "screen.",
         "Onboarding-2-scores"),
        ("User guide",
         "Everything else — the tiles, the lanes, the sounds a channel is given — is " +
         "written in the guide, and the \"?\" at the end of the row opens it.",
         "Onboarding-3-guide"),
    ]

    private(set) var shown = false
    private(set) var page = 0
    private(set) var level: Double = 0   // How far the shade has come down, 0 to 1
    private(set) var panelUp = false     // Raised only once the screen is covered
    var ticked = OnboardingSetting.dismissed

    // The subjects on the transport row, in global coordinates.
    var playFrame: CGRect = .null
    var scoresFrame: CGRect = .null
    var guideFrame: CGRect = .null
    var rowFrame: CGRect = .null

    static let raiseDelay = 0.5
    static let fadeSeconds = 0.4

    func show() {
        guard !shown else { return }
        shown = true
        page = 0
        withAnimation(.linear(duration: OnboardingState.fadeSeconds).delay(OnboardingState.raiseDelay)) {
            level = 1
        }
        let generation = UUID()
        raising = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + OnboardingState.raiseDelay + OnboardingState.fadeSeconds) {
            if self.shown && self.raising == generation { self.panelUp = true }
        }
    }

    // The press that puts it away is answered at once, and the fog lifts behind it.
    func close() {
        shown = false
        panelUp = false
        raising = nil
        withAnimation(.linear(duration: OnboardingState.fadeSeconds)) { level = 0 }
    }

    func next() {
        if page + 1 < OnboardingState.pages.count { page += 1 } else { close() }
    }

    func toggleTick() {
        ticked.toggle()
        OnboardingSetting.dismissed = ticked
    }

    // The slot the hole is cut to: the subject, a gap either side.
    var subject: CGRect {
        switch page {
        case 0: return playFrame
        case 1: return scoresFrame
        default: return guideFrame
        }
    }

    @ObservationIgnored private var raising: UUID?
}

// The grey over everything, with the slot cut through the row and the light in it.
struct OnboardingShade: View {
    let state: OnboardingState

    static let grey = Style.grey(0x24)
    static let alpha = 0.78
    static let highlightAlpha = 0.5
    static let pulseSeconds = 1.2

    var body: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            let subject = state.subject
            let row = state.rowFrame

            TimelineView(.animation(paused: state.level == 0)) { timeline in
                Canvas { context, size in
                    var sheet = Path(CGRect(origin: .zero, size: size))

                    var hole = CGRect.null
                    if !subject.isNull && !row.isNull {
                        hole = CGRect(x: subject.minX - Controls.gap - origin.x,
                                      y: -origin.y - 1,
                                      width: subject.width + Controls.gap * 2,
                                      height: row.maxY + 1)
                        sheet.addRect(hole)
                    }

                    context.fill(sheet, with: .color(OnboardingShade.grey.opacity(OnboardingShade.alpha)),
                                 style: FillStyle(eoFill: true))

                    if !hole.isNull {
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: OnboardingShade.pulseSeconds)
                        let swell = 0.5 * (1 - cos(2 * .pi * phase / OnboardingShade.pulseSeconds))
                        context.fill(Path(hole), with: .color(.white.opacity(OnboardingShade.highlightAlpha * swell)))
                    }
                }
            }
            .opacity(state.level)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// The panel: a header with the page count, the picture, the words, and the foot with the
// box and Next.
struct OnboardingPanel: View {
    let state: OnboardingState

    static let widthOfPanel: CGFloat = 1.5
    static let bodySize = Controls.fontSize + 1
    static let markSize: CGFloat = 14

    var body: some View {
        let page = OnboardingState.pages[state.page]
        let last = state.page + 1 == OnboardingState.pages.count

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(page.header)
                    .font(Style.font(Controls.fontSize))
                    .foregroundColor(Style.noteText)
                Spacer()
                Text("\(state.page + 1) of \(OnboardingState.pages.count)")
                    .font(Style.font(Controls.fontSize))
                    .foregroundColor(Style.label)
            }
            .frame(height: Controls.rowHeight)
            .padding(.bottom, Controls.gap)

            if let picture = UIImage(named: page.picture) {
                Image(uiImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: picture.size.width)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Controls.gap)
            }

            Text(page.body)
                .font(Style.font(OnboardingPanel.bodySize))
                .foregroundColor(Style.noteText)
                .lineSpacing(OnboardingPanel.bodySize * 0.3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Controls.gap * 2)
                .padding(.top, Controls.gap * 3 - Controls.gap)
                .padding(.bottom, Controls.gap * 3)

            HStack(spacing: 0) {
                Button { state.toggleTick() } label: {
                    RoundedRectangle(cornerRadius: Controls.radius)
                        .fill(Style.controlBackground)
                        .frame(width: Controls.rowHeight, height: Controls.rowHeight)
                        .overlay {
                            if state.ticked {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Style.noteLine)
                                    .frame(width: OnboardingPanel.markSize, height: OnboardingPanel.markSize)
                            }
                        }
                }
                .buttonStyle(.plain)

                Text("Don't show this again")
                    .font(Style.font(Controls.fontSize))
                    .foregroundColor(Style.label)
                    .padding(.leading, Controls.groupGap)

                Spacer(minLength: Controls.gap)

                PushButton(label: last ? "Done" : "Next", width: Controls.width(46)) { state.next() }
            }
            .padding(.bottom, Controls.gap)
        }
        .padding(.horizontal, Controls.inset)
        .padding(.top, Controls.inset)
        .padding(.bottom, Controls.inset - Controls.gap)
        .frame(maxWidth: Controls.panelWidth * OnboardingPanel.widthOfPanel)
        .background(Style.panel)
        .overlay(Rectangle().strokeBorder(Style.frontLine, lineWidth: 1))
    }
}
