import Tint

struct KeyHandler {
    static func handle(key: Key, state: PlayerState, app: Application) {
        // Help overlay captures all keys
        if state.isShowingHelp {
            if case .char("?") = key { state.toggleHelp() }
            else if case .escape = key { state.toggleHelp() }
            return
        }

        // Search mode captures all keys
        if state.isSearching {
            handleSearchKey(key: key, state: state)
            return
        }

        switch key {
        case .char("q"), .ctrlC:
            state.player.stop()
            app.quit()

        case .char("?"):
            state.toggleHelp()

        case .char("c"):
            state.clearFilter()

        case .char("j"), .down:
            state.moveDown()

        case .char("k"), .up:
            state.moveUp()

        case .char("h"):
            state.focusLeft()

        case .char("l"):
            state.focusRight()

        case .tab:
            if state.focus == .sidebar {
                state.focusRight()
            } else {
                state.focusLeft()
            }

        case .left:
            state.scrollLeft()

        case .right:
            state.scrollRight()

        case .enter:
            if state.focus == .sidebar {
                state.focusRight()
            } else {
                state.playSelected()
            }

        case .char(" "):
            state.togglePlayPause()

        case .char("n"):
            state.nextTrack()

        case .char("p"):
            state.previousTrack()

        case .char("H"):
            state.scrollLeft()

        case .char("L"):
            state.scrollRight()

        case .char("0"):
            state.resetHScroll()

        case .char("v"):
            state.cycleVisualizerMode()

        case .char("/"):
            state.startSearch()

        case .escape:
            break

        default:
            break
        }
    }

    private static func handleSearchKey(key: Key, state: PlayerState) {
        switch key {
        case .escape:
            state.cancelSearch()

        case .enter:
            state.commitSearch()

        case .tab:
            state.commitSearch()

        case .backspace:
            state.deleteSearchChar()

        case .char(let c):
            state.appendSearchChar(c)

        default:
            break
        }
    }
}
