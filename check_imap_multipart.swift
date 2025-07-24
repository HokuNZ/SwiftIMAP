#!/usr/bin/env swift

// In IMAP, when fetching multiple body parts, servers typically send:
// 
// Option 1: Separate FETCH responses for each part
// * 3 FETCH (BODY[1] {11}
// Part 1 data)
// * 3 FETCH (BODY[2] {11}
// Part 2 data)
//
// Option 2: Combined in one response (less common)
// * 3 FETCH (BODY[1] {11}
// Part 1 data BODY[2] {11}
// Part 2 data)
//
// The test is trying to simulate Option 2, which is valid but complex

print("=== How IMAP servers typically handle multiple body parts ===")
print("\nOption 1 (Common): Separate FETCH responses")
print("* 3 FETCH (BODY[1] {11}")
print("Part 1 data)")
print("* 3 FETCH (BODY[2] {11}")
print("Part 2 data)")
print("A003 OK Fetch completed")

print("\n\nOption 2 (Less common): Combined response")
print("* 3 FETCH (BODY[1] {11}")
print("Part 1 data BODY[2] {11}")
print("Part 2 data)")
print("A003 OK Fetch completed")

print("\n\n=== The parsing challenge ===")
print("With Option 2, after collecting the first literal:")
print("Line = '* 3 FETCH (BODY[1] {11}~LITERAL~ BODY[2] {11}'")
print("This line is incomplete - it needs the second literal before the closing ')'")
print("\nThe parser needs to detect this and continue collecting literals")