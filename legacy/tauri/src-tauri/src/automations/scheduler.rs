use crate::error::{Error, Result};
use chrono::{DateTime, TimeZone, Utc};
use std::str::FromStr;

/// Next occurrence strictly after `after`, computed in the automation's own
/// timezone so that DST shifts move the wall-clock time correctly.
pub fn next_occurrence(
    rrule_body: &str,
    timezone: &str,
    dtstart_rfc3339: &str,
    after: DateTime<Utc>,
) -> Result<Option<DateTime<Utc>>> {
    let tz: chrono_tz::Tz = timezone
        .parse()
        .map_err(|_| Error::msg(format!("unknown timezone `{timezone}`")))?;
    let dtstart = DateTime::parse_from_rfc3339(dtstart_rfc3339)
        .map_err(|e| Error::msg(format!("bad dtstart `{dtstart_rfc3339}`: {e}")))?
        .with_timezone(&tz);

    let local = dtstart.format("%Y%m%dT%H%M%S").to_string();
    let body = rrule_body.trim().trim_start_matches("RRULE:");
    let spec = format!("DTSTART;TZID={timezone}:{local}\nRRULE:{body}");

    let set = rrule::RRuleSet::from_str(&spec)
        .map_err(|e| Error::msg(format!("invalid schedule: {e}")))?;

    // rrule's `after` bound is inclusive, so step past it to get a strictly
    // later occurrence. Without this the scheduler would refire the same slot.
    let strictly_after = after + chrono::Duration::seconds(1);
    let after_tz = rrule::Tz::Tz(tz).from_utc_datetime(&strictly_after.naive_utc());
    let result = set.after(after_tz).all(1);
    Ok(result
        .dates
        .first()
        .map(|d| d.with_timezone(&Utc)))
}

/// Presets offered in the UI, mapped to RRULE bodies.
pub fn preset_rrule(preset: &str, hour: u32, minute: u32) -> Option<String> {
    Some(match preset {
        "hourly" => format!("FREQ=HOURLY;BYMINUTE={minute};BYSECOND=0"),
        "daily" => format!("FREQ=DAILY;BYHOUR={hour};BYMINUTE={minute};BYSECOND=0"),
        "weekdays" => format!(
            "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR={hour};BYMINUTE={minute};BYSECOND=0"
        ),
        "weekly" => format!("FREQ=WEEKLY;BYDAY=MO;BYHOUR={hour};BYMINUTE={minute};BYSECOND=0"),
        _ => return None,
    })
}

/// The next `count` occurrences, for the "next runs" preview in the form.
pub fn preview(
    rrule_body: &str,
    timezone: &str,
    dtstart_rfc3339: &str,
    count: usize,
) -> Result<Vec<DateTime<Utc>>> {
    let mut out = Vec::new();
    let mut cursor = Utc::now();
    // Each step starts from the previous hit, which `next_occurrence` excludes.
    for _ in 0..count.min(10) {
        match next_occurrence(rrule_body, timezone, dtstart_rfc3339, cursor)? {
            Some(next) => {
                out.push(next);
                cursor = next;
            }
            None => break,
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn utc(y: i32, m: u32, d: u32, h: u32, mi: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, m, d, h, mi, 0).unwrap()
    }

    #[test]
    fn daily_fires_at_the_configured_local_hour() {
        let next = next_occurrence(
            "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0",
            "America/Sao_Paulo",
            "2026-01-01T09:00:00-03:00",
            utc(2026, 3, 10, 13, 0),
        )
        .unwrap()
        .unwrap();
        // 09:00 in Sao Paulo (UTC-3) is 12:00 UTC, so the next fire is the following day.
        assert_eq!(next, utc(2026, 3, 11, 12, 0));
    }

    #[test]
    fn dst_change_keeps_the_local_wall_clock_time() {
        // New York moves to DST on 2026-03-08. 09:00 local is 14:00 UTC before
        // the change and 13:00 UTC after it.
        let before = next_occurrence(
            "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0",
            "America/New_York",
            "2026-01-01T09:00:00-05:00",
            utc(2026, 3, 6, 15, 0),
        )
        .unwrap()
        .unwrap();
        assert_eq!(before, utc(2026, 3, 7, 14, 0));

        let after = next_occurrence(
            "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0",
            "America/New_York",
            "2026-01-01T09:00:00-05:00",
            utc(2026, 3, 9, 15, 0),
        )
        .unwrap()
        .unwrap();
        assert_eq!(after, utc(2026, 3, 10, 13, 0));
    }

    #[test]
    fn weekdays_preset_skips_the_weekend() {
        let body = preset_rrule("weekdays", 9, 0).unwrap();
        // 2026-09-25 is a Friday; the next weekday fire is Monday the 28th.
        let next = next_occurrence(&body, "UTC", "2026-01-01T09:00:00+00:00", utc(2026, 9, 25, 10, 0))
            .unwrap()
            .unwrap();
        assert_eq!(next, utc(2026, 9, 28, 9, 0));
    }

    #[test]
    fn preview_returns_distinct_increasing_times() {
        let times = preview("FREQ=MINUTELY;INTERVAL=2", "UTC", "2026-01-01T00:00:00+00:00", 3).unwrap();
        assert_eq!(times.len(), 3);
        assert!(times[0] < times[1] && times[1] < times[2]);
    }

    #[test]
    fn invalid_input_is_an_error_not_a_panic() {
        assert!(next_occurrence("FREQ=NONSENSE", "UTC", "2026-01-01T00:00:00+00:00", Utc::now()).is_err());
        assert!(next_occurrence("FREQ=DAILY", "Mars/Olympus", "2026-01-01T00:00:00+00:00", Utc::now()).is_err());
        assert!(next_occurrence("FREQ=DAILY", "UTC", "not-a-date", Utc::now()).is_err());
    }
}
