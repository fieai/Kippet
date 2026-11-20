import Foundation

extension ClipboardStore {
    func prewarmOCR() {
        // Pop from the end so both the newest history and fresh captures are processed first.
        for clip in clips.reversed() where needsImageRecognition(clip) {
            if queuedOCR.insert(clip.id).inserted { pendingOCR.append(clip.id) }
        }
        startOCRBackfill()
    }

    func recognizeText(_ id: Clip.ID) async -> String? {
        if let text = clips.first(where: { $0.id == id })?.recognizedText { return text }
        return await recognitionTask(for: id)?.value
    }

    private func recognitionTask(for id: Clip.ID) -> Task<String?, Never>? {
        guard let clip = clips.first(where: { $0.id == id }), clip.hasPreviewImage else { return nil }
        let needsText = clip.recognizedText == nil
        let needsBarcodes = clip.barcodePayloads == nil
        guard needsText || needsBarcodes else { return nil }
        if let existing = ocrJobs[id], existing.clip.hasSamePreviewImage(as: clip) { return existing.task }

        let token = UUID()
        let job = Task(priority: .utility) { [weak self] () -> String? in
            guard let image = await self?.processImage({ try? clip.readPreviewImage() }) else {
                if self?.ocrJobs[id]?.token == token { self?.ocrJobs.removeValue(forKey: id) }
                return nil
            }
            let result = await ClipOCR.recognize(image.data, text: needsText, barcodes: needsBarcodes)
            guard let self, ocrJobs[id]?.token == token else { return nil }
            ocrJobs.removeValue(forKey: id)
            guard result.text != nil || result.barcodePayloads != nil,
                  let index = clips.firstIndex(where: { $0.id == id }),
                  clips[index].hasSamePreviewImage(as: clip) else { return nil }
            var updated = clips[index]
            updated.recognizedText = result.text ?? updated.recognizedText
            updated.barcodePayloads = result.barcodePayloads ?? updated.barcodePayloads
            clips[index] = updated
            save(upserting: [updated])
            return updated.recognizedText
        }
        ocrJobs[id] = OCRJob(clip: clip, token: token, task: job)
        return job
    }

    func queueOCR(_ clip: Clip) {
        guard needsImageRecognition(clip), queuedOCR.insert(clip.id).inserted else { return }
        pendingOCR.append(clip.id)
        startOCRBackfill()
    }

    private func needsImageRecognition(_ clip: Clip) -> Bool {
        (clip.recognizedText == nil || clip.barcodePayloads == nil) && clip.hasPreviewImage
    }

    private func startOCRBackfill() {
        guard ocrBackfill == nil, !pendingOCR.isEmpty else { return }
        ocrBackfill = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled, let id = self?.pendingOCR.popLast() {
                self?.queuedOCR.remove(id)
                let task = self?.recognitionTask(for: id)
                _ = await task?.value
            }
            self?.ocrBackfill = nil
        }
    }
}

struct OCRJob {
    let clip: Clip
    let token: UUID
    let task: Task<String?, Never>
}
