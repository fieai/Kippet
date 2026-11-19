import Foundation
import ImageIO
import Vision

enum ClipOCR {
    private static let queue = DispatchQueue(label: "Kippet.ocr", qos: .utility)

    struct Result: Sendable {
        var text: String? = nil
        var barcodePayloads: [String]? = nil
    }

    static func recognize(_ data: Data, text: Bool = true, barcodes: Bool = true) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: autoreleasepool {
                    recognizeImage(data, text: text, barcodes: barcodes)
                })
            }
        }
    }

    private static func recognizeImage(_ data: Data, text: Bool, barcodes: Bool) -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4_096,
              ] as CFDictionary) else { return Result() }

        let textRequest = text ? makeTextRequest() : nil
        let barcodeRequest = barcodes ? VNDetectBarcodesRequest() : nil
        barcodeRequest?.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]
        let requests: [VNRequest] = [textRequest as VNRequest?, barcodeRequest as VNRequest?].compactMap { $0 }
        // Keep the first scan independent of Neural Engine model compilation.
        for request in requests { preferCPU(for: request) }
        let handler = VNImageRequestHandler(cgImage: image)
        let completed = (try? handler.perform(requests)) != nil

        let recognizedText = textRequest.flatMap { request -> String? in
            guard request.results != nil || completed else { return nil }
            let observations = request.results ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return String(lines.joined(separator: "\n").prefix(16_384))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let barcodePayloads = barcodeRequest.flatMap { request -> [String]? in
            guard request.results != nil || completed else { return nil }
            let observations = request.results ?? []
            var seen: Set<String> = []
            return observations.compactMap(\.payloadStringValue).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        return Result(text: recognizedText, barcodePayloads: barcodePayloads)
    }

    private static func makeTextRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let supported = try? request.supportedRecognitionLanguages() {
            let languages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
            if !languages.isEmpty { request.recognitionLanguages = languages }
        }
        request.automaticallyDetectsLanguage = true
        return request
    }

    private static func preferCPU(for request: VNRequest) {
        if let stages = try? request.supportedComputeStageDevices {
            for (stage, devices) in stages {
                if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
    }
}
