use anyhow::{Context, Result};
use std::sync::OnceLock;
use tract_onnx::prelude::*;

static ML_ENGINE: OnceLock<MlEngine> = OnceLock::new();

/// Çevrimdışı Makine Öğrenimi Motoru.
/// ONNX modelini belleğe yükler ve statik özellik dizisinden tehdit skoru hesaplar.
#[allow(clippy::type_complexity)]
pub struct MlEngine {
    model: SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>,
}

impl Default for MlEngine {
    fn default() -> Self {
        Self::new().expect("Gömülü ONNX modeli yüklenemedi")
    }
}

impl MlEngine {
    /// defense_rf.onnx modelini Rust binary'si içerisinden yükler.
    pub fn new() -> Result<Self> {
        let model_bytes = include_bytes!("../../../ml_pipeline/defense_rf.onnx");
        let mut reader = std::io::Cursor::new(model_bytes);

        let model = tract_onnx::onnx()
            .model_for_read(&mut reader)?
            .with_input_fact(0, f32::fact([1, 5]).into())?
            .into_optimized()?
            .into_runnable()?;

        Ok(Self { model })
    }

    /// Global (Singleton) ML motorunu getirir (thread-safe, tek seferlik yükleme).
    pub fn global() -> &'static Self {
        ML_ENGINE.get_or_init(|| Self::new().expect("Global ML modeli başlatılamadı"))
    }

    /// 5 adet özellik alır, ONNX modeline sokar ve `[0.0, 1.0]` arası
    /// Zararlı (Malicious) olma olasılığını döndürür.
    pub fn predict(&self, features: [f32; 5]) -> Result<f32> {
        let tensor = tract_ndarray::Array2::from_shape_vec((1, 5), features.to_vec())
            .context("Tensor oluşturulamadı")?
            .into_tensor();

        let result = self.model.run(tvec!(tensor.into()))?;
        let output_tensor = &result[1];
        let probs = output_tensor.to_array_view::<f32>()?;

        let malicious_prob = probs[[0, 1]];
        Ok(malicious_prob)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_model_inference_benign() {
        let engine = MlEngine::new().unwrap();

        // Düşük entropi, 0 şüpheli import, imzalı -> Benign
        // [entropy, size, imports, sig, packed]
        let features = [4.1, 102400.0, 0.0, 1.0, 0.0];
        let score = engine.predict(features).unwrap();

        assert!(
            score < 0.3,
            "Temiz dosyanın skoru düşük olmalı. Çıktı: {}",
            score
        );
    }

    #[test]
    fn test_model_inference_malicious() {
        let engine = MlEngine::new().unwrap();

        // Yüksek entropi, çok sayıda import, imzasız, packed -> Malicious
        let features = [7.9, 50000.0, 20.0, 0.0, 1.0];
        let score = engine.predict(features).unwrap();

        assert!(
            score > 0.7,
            "Zararlı dosyanın skoru yüksek olmalı. Çıktı: {}",
            score
        );
    }
}
