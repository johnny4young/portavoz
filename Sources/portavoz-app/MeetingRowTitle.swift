import PortavozCore

/// Rows and the meeting page show the meeting's name, not the file-style date
/// and time the title template can put in front of it; the date is shown
/// beside it already.
enum MeetingRowTitle {
    static func display(_ title: String) -> String {
        TitleTemplate.withoutDateTimePrefix(title)
    }
}
