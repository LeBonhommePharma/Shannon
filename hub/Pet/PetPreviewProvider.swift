// PetPreviewProvider.swift — visual QA for the pet system.
//
// Every pet in every state, on the hub's real card colour, at both the shipping
// 32pt size and a 4× blow-up. Open this file in Xcode's canvas to check a
// drawing without launching the hub.

#if DEBUG
import SwiftUI

struct PetGalleryView: View {
    /// The hub's warm off-white card. Pets are only ever drawn on this.
    private static let card = Color(.sRGB, red: 0xFA / 255, green: 0xF8 / 255,
                                    blue: 0xF5 / 255, opacity: 1)

    /// Brand tints from hub/agent_identity.py, in the pet's own order.
    private static let agentTints: [PetKind: Color] = [
        .owl:     Color(.sRGB, red: 1.00, green: 0.72, blue: 0.10, opacity: 1),
        .raven:   Color(.sRGB, red: 0.68, green: 0.28, blue: 0.98, opacity: 1),
        .fox:     Color(.sRGB, red: 1.00, green: 0.50, blue: 0.08, opacity: 1),
        .dolphin: Color(.sRGB, red: 0.30, green: 0.55, blue: 1.00, opacity: 1),
        .wolf:    Color(.sRGB, red: 0.72, green: 0.50, blue: 0.28, opacity: 1),
        .beaver:  Color(.sRGB, red: 0.20, green: 0.85, blue: 0.45, opacity: 1),
        .gear:    Color(.sRGB, red: 0.15, green: 0.70, blue: 0.80, opacity: 1),
    ]

    /// 1 = shipping size. Bump to inspect line weight and path detail.
    let magnification: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("").frame(width: 62, alignment: .leading)
                ForEach(PetAnimationState.allCases, id: \.self) { state in
                    Text(state.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .frame(width: 32 * magnification)
                }
            }
            ForEach(PetKind.allCases, id: \.self) { pet in
                HStack(spacing: 12) {
                    Text(pet.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 62, alignment: .leading)
                    ForEach(PetAnimationState.allCases, id: \.self) { state in
                        PetRenderer(pet: pet, state: state,
                                    agentColor: Self.agentTints[pet] ?? .orange)
                            .scaleEffect(magnification)
                            .frame(width: 32 * magnification, height: 32 * magnification)
                    }
                }
            }
        }
        .padding(18)
        .background(Self.card)
    }
}

struct PetGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        PetGalleryView(magnification: 1)
            .previewDisplayName("Pets — 32pt (shipping)")

        PetGalleryView(magnification: 4)
            .previewDisplayName("Pets — 4× (path detail)")
    }
}
#endif
