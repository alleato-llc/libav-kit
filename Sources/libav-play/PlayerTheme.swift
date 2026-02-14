import Tint

struct PlayerTheme: Theme {
    var primary: Style { Style(fg: .rgb(220, 210, 240)) }
    var secondary: Style { Style(fg: .rgb(150, 130, 180)) }
    var highlight: Style { Style(fg: .white, bg: .rgb(90, 40, 150), bold: true) }
    var accent: Style { Style(fg: .rgb(180, 120, 255), bold: true) }
    var muted: Style { Style(fg: .rgb(100, 80, 130), dim: true) }
    var border: Style { Style(fg: .rgb(120, 90, 170)) }
    var title: Style { Style(fg: .rgb(200, 170, 255), bold: true) }
    var error: Style { Style(fg: .rgb(255, 100, 100), bold: true) }
    var statusBar: Style { Style(fg: .rgb(220, 210, 240), bg: .rgb(40, 20, 60)) }
    var visualizer: Style { Style(fg: .rgb(230, 180, 60)) }
}
