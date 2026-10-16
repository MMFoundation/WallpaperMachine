//! Plain-text rendering of shader diagnostics with source excerpts.
//!
//! The output is stable ASCII: a title, the message, a `name:line:column` header, the source
//! lines around each labelled span with a caret underline, and a trailing help line. Offsets are
//! byte offsets into the source and are clamped to the text, so no input can panic.

use std::fmt::Write as _;

/// Source lines shown before and after a labelled line.
const CONTEXT_LINES: usize = 2;
/// Display width of a tab character.
const TAB_WIDTH: usize = 4;
/// Diagnostic code printed above the message.
const CODE: &str = "shader::diagnostic";

/// Named source text that labels point into.
#[derive(Clone, Debug)]
pub(super) struct ReportSource {
    /// Name shown in the location header.
    pub name: String,
    /// Source text.
    pub text: String,
}

/// A labelled byte range of the source.
#[derive(Clone, Debug)]
pub(super) struct ReportLabel {
    /// Byte offset of the first labelled byte.
    pub start: usize,
    /// Length of the labelled range in bytes.
    pub len: usize,
    /// Text printed next to the underline.
    pub text: Option<String>,
}

/// One diagnostic entry ready for rendering.
#[derive(Clone, Debug)]
pub(super) struct Report {
    /// Human-readable diagnostic message.
    pub message: String,
    /// Stage/pass context rendered as help text.
    pub help: Option<String>,
    /// Source text used for span rendering.
    pub source: Option<ReportSource>,
    /// Labelled spans, the first being the primary one.
    pub labels: Vec<ReportLabel>,
}

impl Report {
    /// Renders this report as stable plain text.
    pub(super) fn render(&self) -> String {
        let mut output = format!("{CODE}\n\n  x {}\n", self.message);
        if let Some(source) = self.source.as_ref().filter(|_| !self.labels.is_empty()) {
            render_excerpt(&mut output, source, &self.labels);
        }
        if let Some(help) = &self.help {
            let _ = writeln!(output, "  help: {help}");
        }
        output
    }
}

/// A label resolved to a line and a display column range.
struct Placed<'a> {
    line: usize,
    column: usize,
    width: usize,
    text: Option<&'a str>,
}

fn render_excerpt(output: &mut String, source: &ReportSource, labels: &[ReportLabel]) {
    let text = source.text.as_str();
    let line_starts = line_starts(text);
    let line_text = |index: usize| -> &str {
        let start = line_starts[index];
        let end = line_starts.get(index + 1).copied().unwrap_or(text.len());
        text[start..end].trim_end_matches(['\n', '\r'])
    };

    let placed = labels
        .iter()
        .map(|label| {
            let start = floor_boundary(text, label.start);
            let end = floor_boundary(text, label.start.saturating_add(label.len)).max(start);
            let line = line_starts.partition_point(|&offset| offset <= start) - 1;
            let content = line_text(line);
            let within = floor_boundary(content, start - line_starts[line]);
            let covered_end = floor_boundary(content, end - line_starts[line]).max(within);
            Placed {
                line,
                column: display_width(&content[..within]),
                width: display_width(&content[within..covered_end]).max(1),
                text: label.text.as_deref(),
            }
        })
        .collect::<Vec<_>>();

    let primary = &placed[0];
    let primary_chars = char_count_before(text, line_starts[primary.line], labels[0].start);
    let _ = writeln!(output, "   ,-[{}:{}:{}]", source.name, primary.line + 1, primary_chars + 1);

    let mut visible = vec![false; line_starts.len()];
    for label in &placed {
        let first = label.line.saturating_sub(CONTEXT_LINES);
        let last = (label.line + CONTEXT_LINES).min(line_starts.len() - 1);
        visible[first..=last].fill(true);
    }
    let digits = line_starts.len().to_string().len().max(3);
    let mut previous = None;
    for index in (0..line_starts.len()).filter(|&index| visible[index]) {
        if previous.is_some_and(|before| index > before + 1) {
            let _ = writeln!(output, " {:>digits$} :", "...");
        }
        previous = Some(index);
        let _ = writeln!(output, " {:>digits$} | {}", index + 1, expand_tabs(line_text(index)));
        let mut on_line = placed.iter().filter(|label| label.line == index).collect::<Vec<_>>();
        on_line.sort_by_key(|label| label.column);
        for label in on_line {
            let mut row = format!(" {:digits$} : {}{}", "", " ".repeat(label.column), "^".repeat(label.width));
            if let Some(name) = label.text {
                row.push(' ');
                row.push_str(name);
            }
            output.push_str(&row);
            output.push('\n');
        }
    }
    let _ = writeln!(output, "   `----");
}

/// Byte offsets at which each line starts; always contains at least offset zero.
fn line_starts(text: &str) -> Vec<usize> {
    std::iter::once(0)
        .chain(text.match_indices('\n').map(|(index, _)| index + 1))
        .collect()
}

/// Largest char boundary at or below `offset`, clamped to the text length.
fn floor_boundary(text: &str, offset: usize) -> usize {
    let mut offset = offset.min(text.len());
    while !text.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

fn char_count_before(text: &str, line_start: usize, offset: usize) -> usize {
    let offset = floor_boundary(text, offset).max(line_start);
    text[line_start..offset].chars().count()
}

fn display_width(text: &str) -> usize {
    text.chars().map(|character| if character == '\t' { TAB_WIDTH } else { 1 }).sum()
}

fn expand_tabs(text: &str) -> String {
    text.replace('\t', &" ".repeat(TAB_WIDTH))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(text: Option<&str>, labels: &[(usize, usize, Option<&str>)]) -> Report {
        Report {
            message: "boom".into(),
            help: Some("stage: Fragment".into()),
            source: text.map(|text| ReportSource { name: "a.frag".into(), text: text.into() }),
            labels: labels
                .iter()
                .map(|&(start, len, text)| ReportLabel { start, len, text: text.map(Into::into) })
                .collect(),
        }
    }

    #[test]
    fn names_message_location_label_and_help() {
        let output = report(Some("one\ntwo bar\nthree"), &[(8, 3, Some("pass"))]).render();
        for expected in ["boom", "a.frag:2:5", "two bar", "^^^ pass", "stage: Fragment"] {
            assert!(output.contains(expected), "missing {expected:?} in\n{output}");
        }
    }

    #[test]
    fn label_at_start_and_end_of_source() {
        let source = "abc\ndef";
        let start = report(Some(source), &[(0, 1, None)]).render();
        assert!(start.contains("a.frag:1:1"), "{start}");
        let end = report(Some(source), &[(source.len(), 0, None)]).render();
        assert!(end.contains("a.frag:2:4") && end.contains('^'), "{end}");
    }

    #[test]
    fn multibyte_offsets_never_panic_and_count_characters() {
        let source = "a\u{e9}\u{4e16}\u{1f600}x";
        let output = report(Some(source), &[(source.find('x').unwrap(), 1, None)]).render();
        assert!(output.contains("a.frag:1:5"), "{output}");
        for start in 0..=source.len() + 2 {
            for len in 0..=source.len() + 2 {
                let _ = report(Some(source), &[(start, len, Some("l"))]).render();
            }
        }
        let _ = report(Some(source), &[(usize::MAX, usize::MAX, None)]).render();
    }

    #[test]
    fn missing_source_or_labels_still_reports_message_and_help() {
        for output in [report(None, &[(0, 1, None)]).render(), report(Some("x"), &[]).render()] {
            assert!(output.contains("boom") && output.contains("stage: Fragment"), "{output}");
            assert!(!output.contains("a.frag"), "{output}");
        }
    }

    #[test]
    fn empty_source_and_crlf_lines_render() {
        assert!(report(Some(""), &[(0, 0, None)]).render().contains("a.frag:1:1"));
        let output = report(Some("a\r\nbb\r\n"), &[(3, 2, None)]).render();
        assert!(output.contains("a.frag:2:1") && !output.contains('\r'), "{output}");
    }

    #[test]
    fn multiple_labels_are_all_underlined_with_their_text() {
        let output = report(
            Some("alpha beta\n\n\n\n\n\n\n\ngamma"),
            &[(0, 5, Some("first")), (6, 4, Some("second")), (18, 5, Some("third"))],
        )
        .render();
        for expected in ["^^^^^ first", "^^^^ second", "^^^^^ third", "gamma", "..."] {
            assert!(output.contains(expected), "missing {expected:?} in\n{output}");
        }
        assert!(output.contains("a.frag:1:1"), "{output}");
    }
}
