import PortavozCore

/// Library rows show the meeting's name, not the file-style date prefix the
/// title template can put in front of it; the row's own second line carries
/// the date.
enum MeetingRowTitle {
    static func display(_ title: String) -> String {
        TitleTemplate.withoutDatePrefix(title)
    }
}
