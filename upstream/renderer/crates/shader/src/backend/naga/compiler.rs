//! Naga-backed GLSL analysis and Metal Shading Language compilation.

use naga::{
    front::glsl,
    valid::{Capabilities, ValidationFlags, Validator},
};

use super::{
    diagnostic::{DiagnosticBuilder, cause_notes},
    metal::MetalEmitter,
};
use crate::{
    CompiledShaderStage, CompiledStageArtifact, CompiledStageCode, ShaderCompiler, ShaderError,
    ShaderResult, ShaderStageKind, ShaderTarget,
    codegen::declarations::functions::MATRIX_INVERSE_POLYFILL_MACRO, legalize::CodegenStageSource,
};

/// Compiler backend that lowers legalized GLSL through Naga.
#[derive(Clone, Debug, Default)]
pub struct NagaCompiler;

impl ShaderCompiler for NagaCompiler {
    type Module = naga::Module;

    fn compile_stage(
        &self,
        target: ShaderTarget,
        stage: ShaderStageKind,
        source: &CodegenStageSource,
    ) -> ShaderResult<CompiledStageArtifact<Self::Module>> {
        if source.stage() != stage {
            return Err(ShaderError::invalid_request(format!(
                "compiler stage {stage:?} does not match legalized source stage {:?}",
                source.stage()
            )));
        }

        let source_text = source.source();
        let source_path = match stage {
            ShaderStageKind::Vertex => "generated/vertex.glsl",
            ShaderStageKind::Fragment => "generated/fragment.glsl",
        };

        let mut options = glsl::Options::from(stage.into_naga());
        if target == ShaderTarget::MetalMsl {
            // Naga's MSL writer has no matrix `inverse`; the legalized source
            // carries a helper for it that only this macro enables.
            let _previous = options
                .defines
                .insert(MATRIX_INVERSE_POLYFILL_MACRO.to_owned(), "1".to_owned());
        }
        let mut frontend = glsl::Frontend::default();
        let module = frontend.parse(&options, source_text).map_err(|err| {
            // One diagnostic per parse error, in the order Naga reports them.
            let mut diagnostics = err
                .errors
                .iter()
                .map(|error| {
                    DiagnosticBuilder::new(stage, "naga glsl parse", source_path)
                        .with_message(error.kind.to_string())
                        .with_source(source_text)
                        .with_labels(error.meta.to_range().map(|range| (range, String::new())))
                        .build()
                })
                .collect::<Vec<_>>();
            if diagnostics.is_empty() {
                diagnostics.push(
                    DiagnosticBuilder::new(stage, "naga glsl parse", source_path)
                        .with_message("glsl parse failed without a diagnostic".to_owned())
                        .with_source(source_text)
                        .build(),
                );
            }

            ShaderError::Compile {
                diagnostics: diagnostics.into_boxed_slice(),
            }
        })?;

        let mut validator = Validator::new(ValidationFlags::default(), Capabilities::default());
        let module_info = validator.validate(&module).map_err(|err| {
            let diagnostic = DiagnosticBuilder::new(stage, "naga validate", source_path)
                .with_message(err.as_inner().to_string())
                .with_source(source_text)
                .with_labels(err.spans().filter_map(|(span, text)| {
                    span.to_range().map(|range| (range, text.clone()))
                }))
                .with_notes(cause_notes(err.as_inner()))
                .build();

            ShaderError::Compile {
                diagnostics: Box::from([diagnostic]),
            }
        })?;

        let code = match target {
            ShaderTarget::Analysis => CompiledStageCode::Analysis,
            ShaderTarget::MetalMsl => CompiledStageCode::MetalMsl(
                MetalEmitter {
                    stage,
                    module: &module,
                    module_info: &module_info,
                    source_text,
                    source_path,
                }
                .emit()?,
            ),
        };

        let compiled_stage = CompiledShaderStage::new(
            stage,
            code,
            Some(source_text.to_owned()),
            Box::from([]),
        );

        Ok(CompiledStageArtifact::new(
            compiled_stage,
            module,
            Box::from([]),
        ))
    }
}

impl ShaderStageKind {
    /// Converts this stage into Naga's stage enum.
    #[must_use]
    pub const fn into_naga(self) -> naga::ShaderStage {
        match self {
            Self::Vertex => naga::ShaderStage::Vertex,
            Self::Fragment => naga::ShaderStage::Fragment,
        }
    }
}
