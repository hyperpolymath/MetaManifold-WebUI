// SPDX-License-Identifier: MPL-2.0
// Parse-only TypeScript/TSX AST and syntactic call/import inventory.
// Uses the measured tree's own frozen-lockfile TypeScript, not a floating parser.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2];
if (!root) throw new Error("Usage: bun ts-structure.ts TREE");
const require = createRequire(join(root, "frontend", "package.json"));
const ts = require("typescript") as typeof import("typescript");
const paths = execFileSync("git", ["-C", root, "ls-files", "-z", "--", "*.ts", "*.tsx", "*.js", "*.jsx", "*.mjs", "*.cjs"], { encoding: "utf8" }).split("\0").filter(Boolean).sort();
const records: unknown[] = [];
for (const path of paths) {
  const filename = join(root, path);
  const source = ts.createSourceFile(filename, readFileSync(filename, "utf8"), ts.ScriptTarget.Latest, true);
  const calls: unknown[] = [], imports: string[] = [], functions: { name: string; ast_sha256: string }[] = [];
  const hash = (text: string) => new Bun.CryptoHasher("sha256").update(text).digest("hex");
  function canonical(node: ts.Node): unknown {
    const value: unknown[] = [ts.SyntaxKind[node.kind]];
    if (ts.isIdentifier(node) || ts.isPrivateIdentifier(node)) value.push(node.text);
    if (ts.isStringLiteralLike(node) || ts.isNumericLiteral(node) || ts.isBigIntLiteral(node)) value.push(node.text);
    ts.forEachChild(node, child => value.push(canonical(child)));
    return value;
  }
  function visit(node: ts.Node, caller: string) {
    let next = caller;
    if (ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isArrowFunction(node) || ts.isMethodDeclaration(node)) {
      let name = node.name?.getText(source) ?? "<anonymous>";
      if ((ts.isArrowFunction(node) || ts.isFunctionExpression(node)) && ts.isVariableDeclaration(node.parent) && node.parent.initializer === node)
        name = node.parent.name.getText(source);
      functions.push({ name, ast_sha256: hash(JSON.stringify(canonical(node))) });
      next = name;
    }
    if (ts.isCallExpression(node) || ts.isNewExpression(node))
      calls.push({ caller, callee: node.expression.getText(source), resolved: false });
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier))
      imports.push(node.moduleSpecifier.text);
    if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword && node.arguments[0] && ts.isStringLiteral(node.arguments[0]))
      imports.push(node.arguments[0].text);
    ts.forEachChild(node, child => visit(child, next));
  }
  visit(source, "<top-level>");
  const diagnostics = (source as unknown as { parseDiagnostics: readonly ts.Diagnostic[] }).parseDiagnostics;
  if (diagnostics.length) throw new Error(`Parse failure: ${path}: ${diagnostics.map(d => ts.flattenDiagnosticMessageText(d.messageText, "\n")).join("; ")}`);
  records.push({ path, language: "typescript", ast_sha256: hash(JSON.stringify(canonical(source))), functions, calls,
    imports: [...new Set(imports)].sort(), limitations: ["syntax-only", "no type checking in this adapter", "syntactic unresolved calls", "no TypeScript dataflow analysis"] });
}
process.stdout.write(JSON.stringify(records) + "\n");
