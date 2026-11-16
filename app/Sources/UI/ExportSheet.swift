import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var o = ExportOptions()
    @State private var bytes: Int?

    private var sizeText: String {
        guard let bytes else { return "Working out the size…" }
        let n = model.selectedScans.count
        let total = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let prefix = o.formats.contains(.jpeg) ? "About " : ""
        if n > 1 {
            let each = ByteCountFormatter.string(fromByteCount: Int64(bytes / n), countStyle: .file)
            return "\(prefix)\(total) in total · \(each) per scan"
        }
        return "\(prefix)\(total)"
    }

    var body: some View {
        let frames = model.selectedScans
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Export").foregroundStyle(Theme.text)
                    Text(frames.map { "Frame \($0.name)" }.joined(separator: ", ")).foregroundStyle(Theme.textDim)
                }
                .font(.l)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.chip().accessibilityLabel("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                Dim(text: "Save as · choose one or more")
                formatRow(.jpeg, "JPG", "JPEG", "Finished photo with your base edit, ready to share")
                formatRow(.baseTIFF, "TIF", "Base TIFF · 16-bit", "Your base edit at full quality, for editing later")
                formatRow(.raw, "RAW", "Raw scan · linear 16-bit", "Straight from the scanner, no conversion")
            }

            if o.formats.contains(.jpeg) {
                VStack(alignment: .leading, spacing: 8) {
                    Dim(text: "Size and quality")
                    Seg(options: [(ExportOptions.Size.full, "Full size"), (.edge3000, "3000 px"), (.edge2000, "2000 px")], selection: $o.size)
                    BarSlider(label: "Quality", value: $o.quality, range: 50...100, defaultValue: 92, format: { String(Int($0)) })
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Dim(text: "Export to")
                FolderBox(url: model.folder) { model.chooseFolder() }
            }

            HStack(spacing: 8) {
                Text(sizeText).font(.m)
                Spacer()
                Button("Cancel") { dismiss() }.chip()
                Button(model.exportLabel) {
                    let opts = o
                    dismiss()
                    Task { await model.export(frames, opts) }
                }
                .chip(.primary, height: 48)
                .disabled(frames.isEmpty || o.formats.isEmpty)
                .opacity(frames.isEmpty || o.formats.isEmpty ? 0.4 : 1)
            }
        }
        .padding(32)
        .frame(width: 720)
        .task(id: o) {
            try? await Task.sleep(for: .milliseconds(150))
            bytes = await model.estimatedBytes(model.selectedScans, o)
        }
        .background(Color(red: 40 / 255, green: 39 / 255, blue: 36 / 255))
        .font(.m)
        .foregroundStyle(Theme.text)
    }

    private func formatRow(_ f: ExportOptions.Format, _ tag: String, _ title: String, _ detail: String) -> some View {
        let on = o.formats.contains(f)
        return         Button { if o.formats.contains(f) { o.formats.remove(f) } else { o.formats.insert(f) } } label: {
            HStack(spacing: 16) {
                Text(tag).font(.pixel(14))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.accent : .white.opacity(0.08)))
                    .foregroundStyle(on ? .white : Theme.text)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                    Dim(text: detail)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
