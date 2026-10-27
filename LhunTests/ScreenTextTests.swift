import Testing
@testable import LhunKit

@Test("A copied screen loses the blanks after each line and the empty lines below it, and keeps blank lines between")
func screenTextTrims() {
    #expect(Tmux.screenText("$ ls  \nA  B\t\n\n$ \n\n\n") == "$ ls\nA  B\n\n$")
}
