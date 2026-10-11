import Testing
@testable import PonteCore

@Test func directionLanguages() {
    #expect(Direction.incoming.source == .ptBR)
    #expect(Direction.outgoing.target == .ptBR)
}
