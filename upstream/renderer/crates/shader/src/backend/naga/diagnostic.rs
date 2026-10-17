//! Naga diagnostic conversion into crate-native diagnostics.

use std::ops::Range;

use crate::{ShaderDiagnostic, ShaderStageKind, SourceSpan};

/// Builder for crate-native diagnostics emitted by Naga integration.
#[derive(Clone, Debug)]
pub(super) struct DiagnosticBuilder {
    /// Shader stage associated with the diagnostic.
    stage: ShaderStageKind,
    /// Compilation pass associated with the diagnostic.
    pass: &'static str,
    /// Generated source path associated with the diagnostic.
    source_path: String,
    /// Human-readable diagnostic message.
    message: String,
    /// Labelled byte ranges of the generated source supplied by Naga, primary first.
    labels: Vec<(Range<usize>, String)>,
    /// Explanation lines supplied by Naga.
    notes: Vec<String>,
    /// Generated source text supplied by Naga integration.
    source: Option<String>,
}

impl DiagnosticBuilder {
    /// Creates a diagnostic builder with required context.
    pub(super) fn new(stage: ShaderStageKind, pass: &'static str, source_path: &str) -> Self {
        Self {
            stage,
            pass,
            source_path: source_path.to_owned(),
            message: String::new(),
            labels: Vec::new(),
            notes: Vec::new(),
            source: None,
        }
    }

    /// Sets the human-readable message.
    pub(super) fn with_message(mut self, message: String) -> Self {
        self.message = message;
        self
    }

    /// Sets the labelled source ranges; the first is the primary one. Naga marks a range it
    /// does not know as undefined, which has no `Range`, so callers skip it.
    pub(super) fn with_labels(
        mut self,
        labels: impl IntoIterator<Item = (Range<usize>, String)>,
    ) -> Self {
        self.labels = labels.into_iter().collect();
        self
    }

    /// Sets the explanation lines.
    pub(super) fn with_notes(mut self, notes: Vec<String>) -> Self {
        self.notes = notes;
        self
    }

    /// Sets generated source text context.
    pub(super) fn with_source(mut self, source: &str) -> Self {
        self.source = Some(source.to_owned());
        self
    }

    /// Builds the crate-native diagnostic.
    pub(super) fn build(self) -> ShaderDiagnostic {
        let diagnostic = ShaderDiagnostic::new(self.message)
            .with_stage(self.stage)
            .with_pass(self.pass)
            .with_generated_source_path(self.source_path);
        let diagnostic = if let Some(source) = self.source {
            diagnostic.with_generated_source(source)
        } else {
            diagnostic
        };

        let mut spans = self.labels.into_iter().filter_map(|(range, text)| {
            SourceSpan::new(range.start, range.end).ok().map(|span| (span, text))
        });
        let diagnostic = match spans.next() {
            Some((primary, text)) => spans.fold(
                diagnostic.with_span(primary).with_label(primary, text),
                |diagnostic, (span, text)| diagnostic.with_label(span, text),
            ),
            None => diagnostic,
        };
        self.notes.into_iter().fold(diagnostic, ShaderDiagnostic::with_note)
    }
}

/// Explanation lines for `error`: each underlying cause, outermost first.
pub(super) fn cause_notes(error: &(dyn std::error::Error + 'static)) -> Vec<String> {
    std::iter::successors(error.source(), |cause| cause.source())
        .map(|cause| cause.to_string())
        .collect()
}
