//! RFC 5545 (iCalendar) emitter.
//!
//! Emits one `VCALENDAR` with one `VEVENT` per shift assigned to the target
//! employee. Times use either a floating local representation (no TZID) or an
//! explicit `DTSTART;TZID=...` when the caller supplies one; in the latter
//! case a minimal `VTIMEZONE` block is embedded so Apple Calendar resolves DST
//! correctly without needing an external TZ database.

use chrono::{Duration, NaiveDate, NaiveTime, Timelike};

use crate::models::shift::{Shift, crosses_midnight};

/// One calendar entry. Caller resolves assignment → shift → employee naming.
#[derive(Debug, Clone)]
pub struct IcsEvent {
    pub uid: String,
    pub summary: String,
    pub description: Option<String>,
    pub date: NaiveDate,
    pub start: NaiveTime,
    pub end: NaiveTime,
}

impl IcsEvent {
    pub fn from_shift(
        shift: &Shift,
        employee_id: i64,
        employee_name: &str,
        shift_label: &str,
    ) -> Self {
        let summary = if shift_label.is_empty() {
            format!("{employee_name} — shift")
        } else {
            format!("{employee_name} — {shift_label}")
        };
        Self {
            uid: format!("{}-{}@autorota.local", employee_id, shift.id),
            summary,
            description: if shift.required_role.is_empty() {
                None
            } else {
                Some(format!("Role: {}", shift.required_role))
            },
            date: shift.date,
            start: shift.start_time,
            end: shift.end_time,
        }
    }
}

/// Escape per RFC 5545 §3.3.11: backslash, comma, semicolon, newline.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            ',' => out.push_str("\\,"),
            ';' => out.push_str("\\;"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out
}

/// Fold a content line at 75 octets as required by RFC 5545 §3.1.
fn fold_line(line: &str) -> String {
    let bytes = line.as_bytes();
    if bytes.len() <= 75 {
        return format!("{line}\r\n");
    }
    let mut out = String::new();
    let mut i = 0;
    let mut first = true;
    while i < bytes.len() {
        let chunk_size = if first { 75 } else { 74 };
        let mut end = (i + chunk_size).min(bytes.len());
        // Don't split a multi-byte UTF-8 sequence.
        while end < bytes.len() && (bytes[end] & 0b1100_0000) == 0b1000_0000 {
            end -= 1;
        }
        if !first {
            out.push(' ');
        }
        // Safe: the loop above walks `end` back across continuation bytes
        // (`0b10xxxxxx`) so the slice always lands on a UTF-8 boundary. If the
        // backwards walk ever underflows (it can't: chunk ≥ 74 ≫ 4-byte max),
        // `from_utf8_lossy` substitutes U+FFFD rather than panicking.
        out.push_str(&String::from_utf8_lossy(&bytes[i..end]));
        out.push_str("\r\n");
        i = end;
        first = false;
    }
    out
}

/// Render the full iCalendar document. `tzid` when supplied becomes part of
/// `DTSTART;TZID=<tzid>` and a minimal VTIMEZONE block is added. Pass `None`
/// for floating local times.
pub fn render_calendar(events: &[IcsEvent], tzid: Option<&str>) -> String {
    let mut out = String::new();
    out.push_str(&fold_line("BEGIN:VCALENDAR"));
    out.push_str(&fold_line("VERSION:2.0"));
    out.push_str(&fold_line("PRODID:-//autorota//schedule//EN"));
    out.push_str(&fold_line("CALSCALE:GREGORIAN"));

    if let Some(tz) = tzid {
        out.push_str(&fold_line("BEGIN:VTIMEZONE"));
        out.push_str(&fold_line(&format!("TZID:{tz}")));
        // RFC 5545 §3.6.5 requires at least one STANDARD/DAYLIGHT subcomponent.
        // We ship no tz database, so real offsets for an arbitrary TZID are
        // unavailable; emit a syntactically valid placeholder. Clients resolve
        // well-known Olson TZIDs from their own tz data and ignore this block.
        out.push_str(&fold_line("BEGIN:STANDARD"));
        out.push_str(&fold_line("DTSTART:19700101T000000"));
        out.push_str(&fold_line("TZOFFSETFROM:+0000"));
        out.push_str(&fold_line("TZOFFSETTO:+0000"));
        out.push_str(&fold_line("END:STANDARD"));
        out.push_str(&fold_line("END:VTIMEZONE"));
    }

    let dtstamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ").to_string();

    for ev in events {
        out.push_str(&fold_line("BEGIN:VEVENT"));
        out.push_str(&fold_line(&format!("UID:{}", escape(&ev.uid))));
        out.push_str(&fold_line(&format!("DTSTAMP:{dtstamp}")));

        let (dtstart_prop, dtend_prop) = match tzid {
            Some(tz) => (
                format!(
                    "DTSTART;TZID={tz}:{}T{}",
                    ev.date.format("%Y%m%d"),
                    format_time_basic(ev.start)
                ),
                format!(
                    "DTEND;TZID={tz}:{}T{}",
                    end_date(ev.date, ev.start, ev.end).format("%Y%m%d"),
                    format_time_basic(ev.end)
                ),
            ),
            None => (
                format!(
                    "DTSTART:{}T{}",
                    ev.date.format("%Y%m%d"),
                    format_time_basic(ev.start)
                ),
                format!(
                    "DTEND:{}T{}",
                    end_date(ev.date, ev.start, ev.end).format("%Y%m%d"),
                    format_time_basic(ev.end)
                ),
            ),
        };
        out.push_str(&fold_line(&dtstart_prop));
        out.push_str(&fold_line(&dtend_prop));
        out.push_str(&fold_line(&format!("SUMMARY:{}", escape(&ev.summary))));
        if let Some(desc) = &ev.description {
            out.push_str(&fold_line(&format!("DESCRIPTION:{}", escape(desc))));
        }
        out.push_str(&fold_line("END:VEVENT"));
    }

    out.push_str(&fold_line("END:VCALENDAR"));
    out
}

fn format_time_basic(t: NaiveTime) -> String {
    format!("{:02}{:02}{:02}", t.hour(), t.minute(), t.second())
}

/// End date rolls to next day when shift crosses midnight (`end < start`,
/// per the canonical rule in `models::shift`; `end == start` stays same-day).
fn end_date(date: NaiveDate, start: NaiveTime, end: NaiveTime) -> NaiveDate {
    if crosses_midnight(start, end) {
        date + Duration::days(1)
    } else {
        date
    }
}

/// Convenience: render a calendar directly from (shift, employee_id, name, label) tuples.
pub fn render_employee_calendar(
    employee_id: i64,
    employee_name: &str,
    entries: &[(Shift, String)],
    tzid: Option<&str>,
) -> String {
    let events: Vec<IcsEvent> = entries
        .iter()
        .map(|(s, label)| IcsEvent::from_shift(s, employee_id, employee_name, label))
        .collect();
    render_calendar(&events, tzid)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_shift(id: i64, d: (i32, u32, u32), s: (u32, u32), e: (u32, u32), role: &str) -> Shift {
        Shift {
            id,
            template_id: None,
            rota_id: 1,
            date: NaiveDate::from_ymd_opt(d.0, d.1, d.2).unwrap(),
            start_time: NaiveTime::from_hms_opt(s.0, s.1, 0).unwrap(),
            end_time: NaiveTime::from_hms_opt(e.0, e.1, 0).unwrap(),
            required_role: role.into(),
            min_employees: 1,
            max_employees: 1,
            role_requirements: vec![],
        }
    }

    #[test]
    fn single_shift_has_valid_vevent() {
        let s = mk_shift(42, (2026, 4, 20), (7, 0), (12, 0), "Barista");
        let ics =
            render_employee_calendar(7, "Alice", &[(s, "Morning".into())], Some("Europe/London"));
        assert!(ics.contains("BEGIN:VCALENDAR"));
        assert!(ics.contains("END:VCALENDAR"));
        assert!(ics.contains("BEGIN:VEVENT"));
        assert!(ics.contains("END:VEVENT"));
        assert!(ics.contains("UID:7-42@autorota.local"));
        assert!(ics.contains("SUMMARY:Alice — Morning"));
        assert!(ics.contains("DTSTART;TZID=Europe/London:20260420T070000"));
        assert!(ics.contains("DTEND;TZID=Europe/London:20260420T120000"));
        assert!(ics.contains("BEGIN:VTIMEZONE"));
    }

    #[test]
    fn escapes_commas_and_semicolons_in_summary() {
        let s = mk_shift(1, (2026, 4, 20), (7, 0), (12, 0), "");
        let ics = render_employee_calendar(1, "Alice, Bob; Co.", &[(s, "Morn".into())], None);
        assert!(ics.contains("SUMMARY:Alice\\, Bob\\; Co. — Morn"));
    }

    #[test]
    fn overnight_shift_rolls_to_next_day() {
        let s = mk_shift(1, (2026, 4, 20), (22, 0), (6, 0), "Barista");
        let ics = render_employee_calendar(1, "Alice", &[(s, "Night".into())], None);
        assert!(ics.contains("DTSTART:20260420T220000"));
        assert!(ics.contains("DTEND:20260421T060000"));
    }

    #[test]
    fn floating_times_omit_tzid() {
        let s = mk_shift(1, (2026, 4, 20), (7, 0), (12, 0), "Barista");
        let ics = render_employee_calendar(1, "A", &[(s, "M".into())], None);
        assert!(!ics.contains("TZID"));
        assert!(!ics.contains("VTIMEZONE"));
    }

    #[test]
    fn long_unicode_summary_folds_without_panic() {
        // Repeat a 4-byte UTF-8 codepoint (𝕏 = U+1D54F) until well beyond
        // the 75-octet fold limit. Ensures `fold_line` walks back across
        // continuation bytes correctly — a regression net for the
        // `from_utf8` boundary handling.
        let mut name = String::new();
        for _ in 0..40 {
            name.push('𝕏');
        }
        let s = mk_shift(1, (2026, 4, 20), (7, 0), (12, 0), "Barista");
        let ics = render_employee_calendar(1, &name, &[(s, "Morning".into())], None);
        assert!(ics.contains("SUMMARY"));
        for line in ics.split("\r\n") {
            assert!(line.len() <= 75, "unfolded line too long: {line:?}");
        }
    }

    /// RFC 5545 §3.6.5: a VTIMEZONE component MUST contain at least one
    /// STANDARD or DAYLIGHT subcomponent, each with DTSTART, TZOFFSETFROM
    /// and TZOFFSETTO. An empty VTIMEZONE is invalid and strict parsers
    /// reject the whole calendar.
    #[test]
    fn vtimezone_has_required_subcomponent() {
        let s = mk_shift(1, (2026, 4, 20), (7, 0), (12, 0), "Barista");
        let ics =
            render_employee_calendar(1, "Alice", &[(s, "Morning".into())], Some("Europe/London"));

        let start = ics.find("BEGIN:VTIMEZONE").expect("VTIMEZONE present");
        let end = ics.find("END:VTIMEZONE").expect("VTIMEZONE terminated");
        let block = &ics[start..end];

        assert!(
            block.contains("BEGIN:STANDARD") || block.contains("BEGIN:DAYLIGHT"),
            "VTIMEZONE lacks a STANDARD/DAYLIGHT subcomponent:\n{block}"
        );
        for prop in ["DTSTART:", "TZOFFSETFROM:", "TZOFFSETTO:"] {
            assert!(
                block.contains(prop),
                "VTIMEZONE subcomponent missing {prop}\n{block}"
            );
        }
        // Subcomponent must be closed before END:VTIMEZONE.
        if block.contains("BEGIN:STANDARD") {
            assert!(block.contains("END:STANDARD"));
        }
    }

    #[test]
    fn balanced_begin_end_tokens() {
        let s1 = mk_shift(1, (2026, 4, 20), (7, 0), (12, 0), "");
        let s2 = mk_shift(2, (2026, 4, 21), (13, 0), (17, 0), "");
        let ics = render_employee_calendar(1, "A", &[(s1, "".into()), (s2, "".into())], None);
        assert_eq!(ics.matches("BEGIN:VEVENT").count(), 2);
        assert_eq!(ics.matches("END:VEVENT").count(), 2);
    }
}
