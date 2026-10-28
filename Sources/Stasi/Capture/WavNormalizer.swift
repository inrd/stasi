import Accelerate
import AVFoundation
import Foundation

struct WavSettings {
    var bitDepth: Int = 24
    var targetPeakDBFS: Double = -1.0
    var maxBoostDB: Double = 30.0
}

struct NormalizationResult {
    var peakBefore: Float
    var peakAfter: Float
    var gainDB: Double
    var duration: Double
    var frames: Int64
    var wasSilent: Bool
}

/// Two-pass peak normalization into a WAV file.
///
/// Pass 1 finds the peak, pass 2 applies gain while writing. Both passes are
/// bounded by `input.length`: `AVAudioFile.read` fails at EOF rather than
/// returning zero frames (see docs/findings.md).
enum WavNormalizer {
    static func normalize(
        source: URL,
        destination: URL,
        settings: WavSettings = WavSettings(),
        progress: ((Double) -> Void)? = nil
    ) throws -> NormalizationResult {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat

        guard format.channelCount > 0, format.sampleRate > 0, input.length > 0 else {
            throw StasiError("The recording is empty.")
        }

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw StasiError("Could not allocate an audio buffer.")
        }

        var lastReported = -1.0
        func report(_ value: Double) {
            guard let progress else { return }
            if value - lastReported >= 0.01 || value >= 1.0 {
                lastReported = value
                progress(value)
            }
        }

        let totalFrames = input.length
        let channelCount = Int(format.channelCount)

        // Pass 1: find the peak.
        var peak: Float = 0
        var scanned: Int64 = 0
        input.framePosition = 0
        while input.framePosition < totalFrames {
            let want = AVAudioFrameCount(min(Int64(chunk), totalFrames - input.framePosition))
            try input.read(into: buffer, frameCount: want)
            let frames = buffer.frameLength
            if frames == 0 { break }

            if let channels = buffer.floatChannelData {
                for channel in 0..<channelCount {
                    var localMax: Float = 0
                    vDSP_maxmgv(channels[channel], 1, &localMax, vDSP_Length(frames))
                    peak = max(peak, localMax)
                }
            }
            scanned += Int64(frames)
            report(0.5 * Double(scanned) / Double(totalFrames))
        }

        // Gain.
        let target = Float(pow(10.0, settings.targetPeakDBFS / 20.0))
        let maxBoost = Float(pow(10.0, settings.maxBoostDB / 20.0))

        var gain: Float = 1
        var wasSilent = false
        if peak <= 1e-7 {
            wasSilent = true
            Log.info("recording is silent; writing without normalization")
        } else {
            gain = min(target / peak, maxBoost)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: settings.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        // Scoped so the writer is released (and the WAV header finalized) here.
        func writeOutput() throws -> Int64 {
            let output = try AVAudioFile(
                forWriting: destination,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            var written: Int64 = 0
            input.framePosition = 0
            while input.framePosition < totalFrames {
                let want = AVAudioFrameCount(min(Int64(chunk), totalFrames - input.framePosition))
                try input.read(into: buffer, frameCount: want)
                let frames = buffer.frameLength
                if frames == 0 { break }

                if gain != 1, let channels = buffer.floatChannelData {
                    for channel in 0..<channelCount {
                        var factor = gain
                        vDSP_vsmul(channels[channel], 1, &factor, channels[channel], 1, vDSP_Length(frames))
                    }
                }

                try output.write(from: buffer)
                written += Int64(frames)
                report(0.5 + 0.5 * Double(written) / Double(totalFrames))
            }
            return written
        }

        let written = try writeOutput()
        report(1.0)

        let duration = Double(written) / format.sampleRate
        let gainDB = gain > 0 ? 20.0 * log10(Double(gain)) : 0

        Log.info(String(
            format: "normalized peak=%.4f gain=%+.2f dB frames=%lld duration=%.2fs -> %@",
            peak, gainDB, written, duration, destination.lastPathComponent
        ))

        return NormalizationResult(
            peakBefore: peak,
            peakAfter: wasSilent ? 0 : min(peak * gain, 1),
            gainDB: gainDB,
            duration: duration,
            frames: written,
            wasSilent: wasSilent
        )
    }
}
