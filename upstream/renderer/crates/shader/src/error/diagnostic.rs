//! Shader diagnostic records.

use super::{SourceSpan, report::{Report, ReportLabel, ReportSource}};
use crate::model::ShaderStageKind;

/// Diagnostic information produced while handling a shader.
#[derive(Clone, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ShaderDiagnostic {
    /// Shader stage associated with the diagnostic, when known.
    stage: Option<ShaderStageKind>,
    /// Pipeline or codegen pass associated with the diagnostic.
    pass: Option<String>,
    /// Source range associated with the diagnostic.
    span: Option<SourceSpan>,
    /// Human-readable diagnostic message.
    message: String,
    /// Path to generated source associated with the diagnostic.
    generated_source_path: Option<String>,
    /// Generated source text associated with the diagnostic.
    #[cfg_attr(feature = "serde", serde(default, skip_serializing))]
    generated_source: Option<String>,
    /// Labelled source ranges with their text, the first being the primary one. Only the
    /// plain-text report shows them; `span` carries the primary range.
    #[cfg_attr(feature = "serde", serde(default, skip_serializing))]
    labels: Vec<(SourceSpan, String)>,
    /// Further explanation lines, such as the causes behind the message.
    #[cfg_attr(feature = "serde", serde(default, skip_serializing))]
    notes: Vec<String>,
}

impl ShaderDiagnostic {
    /// Creates a diagnostic with a message.
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            stage: None,
            pass: None,
            span: None,
            message: message.into(),
            generated_source_path: None,
            generated_source: None,
            labels: Vec::new(),
            notes: Vec::new(),
        }
    }

    /// Sets the shader stage context.
    #[must_use]
    pub fn with_stage(mut self, stage: ShaderStageKind) -> Self {
        self.stage = Some(stage);
        self
    }

    /// Sets the codegen or pipeline pass context.
    #[must_use]
    pub fn with_pass(mut self, pass: impl Into<String>) -> Self {
        self.pass = Some(pass.into());
        self
    }

    /// Sets the source span context.
    #[must_use]
    pub fn with_span(mut self, span: SourceSpan) -> Self {
        self.span = Some(span);
        self
    }

    /// Sets the generated source path context.
    #[must_use]
    pub fn with_generated_source_path(mut self, path: impl Into<String>) -> Self {
        self.generated_source_path = Some(path.into());
        self
    }

    /// Sets generated source text for structured report rendering.
    #[must_use]
    pub fn with_generated_source(mut self, source: impl Into<String>) -> Self {
        self.generated_source = Some(source.into());
        self
    }

    /// Adds a labelled source range; an empty `text` underlines the range without a caption.
    #[must_use]
    pub fn with_label(mut self, span: SourceSpan, text: impl Into<String>) -> Self {
        self.labels.push((span, text.into()));
        self
    }

    /// Adds an explanation line printed after the source excerpt.
    #[must_use]
    pub fn with_note(mut self, note: impl Into<String>) -> Self {
        self.notes.push(note.into());
        self
    }

    /// Returns the shader stage context.
    #[must_use]
    pub const fn stage(&self) -> Option<ShaderStageKind> {
        self.stage
    }

    /// Returns the pass context.
    #[must_use]
    pub fn pass(&self) -> Option<&str> {
        self.pass.as_deref()
    }

    /// Returns the source span context.
    #[must_use]
    pub const fn span(&self) -> Option<SourceSpan> {
        self.span
    }

    /// Returns the diagnostic message.
    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }

    /// Returns the generated source path context.
    #[must_use]
    pub fn generated_source_path(&self) -> Option<&str> {
        self.generated_source_path.as_deref()
    }

    /// Returns the labelled source ranges and their text.
    #[must_use]
    pub fn labels(&self) -> &[(SourceSpan, String)] {
        &self.labels
    }

    /// Returns the explanation lines.
    #[must_use]
    pub fn notes(&self) -> &[String] {
        &self.notes
    }

    /// Renders this diagnostic as plain text using optional source text.
    #[must_use]
    pub fn render_report(&self, source: Option<&str>) -> String {
        let source = self.generated_source.as_deref().or(source).map(|text| ReportSource {
            name: self
                .generated_source_path()
                .unwrap_or("generated/shader.glsl")
                .to_owned(),
            text: text.to_owned(),
        });
        let labels = if self.labels.is_empty() {
            self.span()
                .map(|span| ReportLabel {
                    start: span.start(),
                    len: span.end().saturating_sub(span.start()),
                    text: self.pass().map(ToOwned::to_owned),
                })
                .into_iter()
                .collect()
        } else {
            self.labels
                .iter()
                .map(|(span, text)| ReportLabel {
                    start: span.start(),
                    len: span.end().saturating_sub(span.start()),
                    text: (!text.is_empty()).then(|| text.clone()),
                })
                .collect()
        };
        let help_parts = [
            self.stage().map(|stage| format!("stage: {stage:?}")),
            self.pass().map(|pass| format!("pass: {pass}")),
            self.generated_source_path()
                .map(|path| format!("source: {path}")),
        ];
        let help = help_parts
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(", ");

        Report {
            message: self.message().to_owned(),
            help: (!help.is_empty()).then_some(help),
            source,
            labels,
            notes: self.notes.clone(),
        }
        .render()
    }
}
