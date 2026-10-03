/// The menus' music (#126): the briefing fades it out as it starts (#130). #126 supplies the implementation; until
/// then the app plays none (`SilentMenuMusic`).
protocol MenuMusic: AnyObject {
    /// Fades the menu music out, if it's playing. Calling it again while it's fading or silent does nothing.
    func fadeOut()
}

/// No menu music: the app's until #126.
final class SilentMenuMusic: MenuMusic {
    func fadeOut() {}
}
