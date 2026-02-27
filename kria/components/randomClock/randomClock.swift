import SwiftUI

struct RandomClockFeatureView: View {
    @StateObject private var randomClockViewModel = RandomClockViewModel()

    init() {}

    var body: some View {
        RandomClockCardView(randomClockViewModel: randomClockViewModel)
    }
}
