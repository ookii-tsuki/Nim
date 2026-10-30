// N# metamorphic oracle: `nsoracle --mutate <outdir> <expected> <main.ns> [module.ns ...]`.
//
// Rewrites a test with changes that cannot alter its meaning -- `x` to `this.x`,
// `=> e` to `{ return e; }`, `var` to the explicit type, extra parentheses, fully
// qualified type names -- and keeps a mutant only after Roslyn has compiled it and
// run it: it must print what the original prints (`<expected>`). The mutants are
// therefore valid C# with a known result, and one that N# gets wrong is a bug in
// N#, never in the mutator. nsharp/tests/run_mutate.sh feeds them to N#.
//
// Writes `<outdir>/<mutation>.ns` for every mutation that applies and verifies, and
// prints one `<status> <mutation> [detail]` line per mutation on stdout:
//
//   ok         the mutant is valid and prints the expected output (file written)
//   unchanged  the mutation found nothing to change in this test
//   invalid    the mutant does not compile (a defect in the mutator; detail = error)
//   differs    the mutant compiles but prints something else (the same)
//
// Exit status 2 means the original itself did not compile or print the expectation.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using static Microsoft.CodeAnalysis.CSharp.SyntaxFactory;

static class Mutate
{
    static readonly string[] AllMutations =
    {
        "this", "block-bodies", "expr-bodies", "explicit-types", "use-var", "parens", "qualify",
    };

    static int counter;

    static string Norm(string s) => s.Replace("\r\n", "\n").TrimEnd('\n');

    public static int Run(string[] args)
    {
        if (args.Length < 3)
        {
            Console.Error.WriteLine("usage: nsoracle --mutate <outdir> <expected> <main.ns> [module.ns ...]");
            return 2;
        }
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("en-US");

        var outDir = args[0];
        var expected = Norm(File.ReadAllText(args[1]));
        var mainPath = Path.GetFullPath(args[2]);
        Directory.CreateDirectory(outDir);

        var refs = new List<MetadataReference>();
        var tpa = (string)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES");
        if (tpa != null)
            foreach (var p in tpa.Split(Path.PathSeparator))
                if (p.Length > 0) refs.Add(MetadataReference.CreateFromFile(p));

        var mainTree = CSharpSyntaxTree.ParseText(File.ReadAllText(mainPath), path: mainPath);
        var siblings = args.Skip(3)
            .Select(a => CSharpSyntaxTree.ParseText(File.ReadAllText(a), path: Path.GetFullPath(a)))
            .ToList();

        CSharpCompilation Compile(SyntaxTree main) =>
            CSharpCompilation.Create("mut" + counter++, new[] { main }.Concat(siblings), refs,
                new CSharpCompilationOptions(OutputKind.ConsoleApplication, allowUnsafe: true));

        var original = Compile(mainTree);
        var bad = original.GetDiagnostics().Where(d => d.Severity == DiagnosticSeverity.Error).ToList();
        if (bad.Count > 0)
        {
            Console.Error.WriteLine("nsoracle: the original does not compile: " + bad[0]);
            return 2;
        }
        var originalOut = RunProgram(original, out var originalErr);
        if (originalOut == null)
        {
            Console.Error.WriteLine("nsoracle: the original does not run: " + originalErr);
            return 2;
        }
        if (Norm(originalOut) != expected)
        {
            Console.Error.WriteLine("nsoracle: the original prints something other than the expectation");
            return 2;
        }

        var wanted = (Environment.GetEnvironmentVariable("NS_MUTATIONS") ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries);
        var model = original.GetSemanticModel(mainTree);
        var root = mainTree.GetRoot();
        foreach (var name in AllMutations)
        {
            if (wanted.Length > 0 && !wanted.Contains(name)) continue;
            CSharpSyntaxRewriter rw = name switch
            {
                "this" => new ThisRw(model),
                "block-bodies" => new BlockBodiesRw(model),
                "expr-bodies" => new ExprBodiesRw(),
                "explicit-types" => new ExplicitTypesRw(model),
                "use-var" => new UseVarRw(model),
                "parens" => new ParensRw(),
                _ => new QualifyRw(model),
            };
            string text;
            try
            {
                text = rw.Visit(root).ToFullString();
            }
            catch (Exception e)
            {
                Console.WriteLine("invalid " + name + " mutator crashed: " + e.Message.Replace('\n', ' '));
                continue;
            }
            if (text == mainTree.ToString())
            {
                Console.WriteLine("unchanged " + name);
                continue;
            }
            var tree = CSharpSyntaxTree.ParseText(text, path: mainPath);
            var comp = Compile(tree);
            var errors = comp.GetDiagnostics().Where(d => d.Severity == DiagnosticSeverity.Error).ToList();
            if (errors.Count > 0)
            {
                var pos = errors[0].Location.GetLineSpan().StartLinePosition;
                Console.WriteLine("invalid " + name + " " + errors[0].Id + " at " + (pos.Line + 1) + ":" +
                                  (pos.Character + 1) + " " + errors[0].GetMessage().Replace('\n', ' '));
                File.WriteAllText(Path.Combine(outDir, name + ".invalid.ns"), text);
                continue;
            }
            var got = RunProgram(comp, out var err);
            if (got == null || Norm(got) != expected)
            {
                Console.WriteLine("differs " + name + " " + (err ?? "different output"));
                File.WriteAllText(Path.Combine(outDir, name + ".differs.ns"), text);
                continue;
            }
            File.WriteAllText(Path.Combine(outDir, name + ".ns"), text);
            Console.WriteLine("ok " + name);
        }
        return 0;
    }

    // Runs the program in this process and returns what it wrote to stdout; null
    // when it cannot be emitted or started. An exception that escapes `Main` ends
    // the output there, as it does for the real program.
    static string RunProgram(CSharpCompilation comp, out string error)
    {
        error = null;
        using var ms = new MemoryStream();
        var emit = comp.Emit(ms);
        if (!emit.Success)
        {
            error = emit.Diagnostics.FirstOrDefault(d => d.Severity == DiagnosticSeverity.Error)?.ToString();
            return null;
        }
        var asm = Assembly.Load(ms.ToArray());
        var entry = asm.EntryPoint;
        if (entry == null)
        {
            error = "no entry point";
            return null;
        }
        var oldOut = Console.Out;
        var oldErr = Console.Error;
        var sw = new StringWriter();
        Console.SetOut(sw);
        Console.SetError(TextWriter.Null);
        try
        {
            entry.Invoke(null, entry.GetParameters().Length == 0 ? null : new object[] { new string[0] });
        }
        catch (TargetInvocationException)
        {
        }
        finally
        {
            Console.SetOut(oldOut);
            Console.SetError(oldErr);
        }
        return sw.ToString();
    }

    // --- helpers ----------------------------------------------------------------

    static bool ContainsAnonymous(ITypeSymbol t)
    {
        switch (t)
        {
            case null:
                return false;
            case IArrayTypeSymbol a:
                return ContainsAnonymous(a.ElementType);
            case INamedTypeSymbol n:
                return n.IsAnonymousType || n.TypeArguments.Any(ContainsAnonymous);
            default:
                return false;
        }
    }

    static string Display(SemanticModel m, ITypeSymbol t, int position)
    {
        if (t == null || t.TypeKind == TypeKind.Error || t.TypeKind == TypeKind.Dynamic ||
            t.TypeKind == TypeKind.FunctionPointer || ContainsAnonymous(t))
            return null;
        return t.ToMinimalDisplayString(m, position);
    }

    static BlockSyntax BlockFor(ExpressionSyntax e, bool isVoid)
    {
        StatementSyntax st =
            e is ThrowExpressionSyntax t ? ThrowStatement(t.Expression)
            : isVoid ? ExpressionStatement(e)
            : ReturnStatement(e);
        return Block(st).NormalizeWhitespace();
    }

    // --- this -------------------------------------------------------------------

    // `x` -> `this.x` for an instance field, property, method or event the program
    // names bare, wherever C# allows `this`.
    sealed class ThisRw : CSharpSyntaxRewriter
    {
        readonly SemanticModel m;
        public ThisRw(SemanticModel m) { this.m = m; }

        public override SyntaxNode VisitIdentifierName(IdentifierNameSyntax node)
        {
            if (!Applies(node)) return base.VisitIdentifierName(node);
            return MemberAccessExpression(SyntaxKind.SimpleMemberAccessExpression, ThisExpression(),
                IdentifierName(node.Identifier.WithoutTrivia())).WithTriviaFrom(node);
        }

        bool Applies(IdentifierNameSyntax n)
        {
            if (n.IsVar) return false;
            var p = n.Parent;
            if (p is MemberAccessExpressionSyntax ma && ma.Name == n) return false;
            if (p is MemberBindingExpressionSyntax || p is NameColonSyntax || p is NameEqualsSyntax ||
                p is AnonymousObjectMemberDeclaratorSyntax || p is NameMemberCrefSyntax)
                return false;
            if (p is AssignmentExpressionSyntax a && a.Left == n && a.Parent is InitializerExpressionSyntax)
                return false;
            foreach (var anc in n.Ancestors())
            {
                if (anc is AttributeSyntax || anc is ConstructorInitializerSyntax ||
                    anc is UsingDirectiveSyntax || anc is PrimaryConstructorBaseTypeSyntax)
                    return false;
                if (anc is InvocationExpressionSyntax inv &&
                    inv.Expression is IdentifierNameSyntax { Identifier.ValueText: "nameof" } &&
                    m.GetSymbolInfo(inv).Symbol == null)
                    return false;
                if (anc is EqualsValueClauseSyntax e)
                {
                    if (e.Parent is VariableDeclaratorSyntax vd &&
                        (vd.Parent?.Parent is FieldDeclarationSyntax || vd.Parent?.Parent is EventFieldDeclarationSyntax))
                        return false;
                    if (e.Parent is PropertyDeclarationSyntax) return false;
                }
                if (anc is MemberDeclarationSyntax) break;
            }
            var s = m.GetSymbolInfo(n).Symbol;
            if (s == null) return false;
            bool instance = s switch
            {
                IFieldSymbol f => !f.IsStatic && !f.IsConst,
                IPropertySymbol pr => !pr.IsStatic,
                IMethodSymbol me => me.MethodKind == MethodKind.Ordinary && !me.IsStatic,
                IEventSymbol ev => !ev.IsStatic,
                _ => false,
            };
            if (!instance) return false;
            if (s.ContainingType == null ||
                (s.ContainingType.TypeKind != TypeKind.Class && s.ContainingType.TypeKind != TypeKind.Struct))
                return false;
            // `Color.Red` with a field `Color`: the type, not the field.
            if (p is MemberAccessExpressionSyntax outer && outer.Expression == n &&
                m.GetSymbolInfo(outer).Symbol?.IsStatic == true)
                return false;
            var enc = m.GetEnclosingSymbol(n.SpanStart);
            while (enc is IMethodSymbol { MethodKind: MethodKind.AnonymousFunction or MethodKind.LocalFunction } lf)
            {
                if (lf.IsStatic) return false;
                enc = lf.ContainingSymbol;
            }
            if (enc == null || enc.IsStatic || enc is IFieldSymbol) return false;
            var owner = enc.ContainingType;
            if (owner == null || (owner.TypeKind != TypeKind.Class && owner.TypeKind != TypeKind.Struct))
                return false;
            for (var t = owner; t != null; t = t.BaseType)
                if (SymbolEqualityComparer.Default.Equals(t.OriginalDefinition, s.ContainingType.OriginalDefinition))
                    return true;
            return false;
        }
    }

    // --- block-bodies -----------------------------------------------------------

    // `=> e;` -> `{ return e; }` (`{ e; }` when it returns nothing).
    sealed class BlockBodiesRw : CSharpSyntaxRewriter
    {
        readonly SemanticModel m;
        public BlockBodiesRw(SemanticModel m) { this.m = m; }

        static bool Plain(ExpressionSyntax e) => !(e is RefExpressionSyntax);

        public override SyntaxNode VisitMethodDeclaration(MethodDeclarationSyntax node)
        {
            var v = (MethodDeclarationSyntax)base.VisitMethodDeclaration(node);
            if (node.ExpressionBody == null || !Plain(node.ExpressionBody.Expression) ||
                node.Modifiers.Any(SyntaxKind.AsyncKeyword) || node.ReturnType is RefTypeSyntax)
                return v;
            var sym = m.GetDeclaredSymbol(node);
            if (sym == null) return v;
            return v.WithExpressionBody(null).WithSemicolonToken(default)
                .WithBody(BlockFor(v.ExpressionBody.Expression, sym.ReturnsVoid)
                    .WithTrailingTrivia(v.SemicolonToken.TrailingTrivia));
        }

        public override SyntaxNode VisitLocalFunctionStatement(LocalFunctionStatementSyntax node)
        {
            var v = (LocalFunctionStatementSyntax)base.VisitLocalFunctionStatement(node);
            if (node.ExpressionBody == null || !Plain(node.ExpressionBody.Expression) ||
                node.Modifiers.Any(SyntaxKind.AsyncKeyword) || node.ReturnType is RefTypeSyntax)
                return v;
            if (m.GetDeclaredSymbol(node) is not IMethodSymbol sym) return v;
            return v.WithExpressionBody(null).WithSemicolonToken(default)
                .WithBody(BlockFor(v.ExpressionBody.Expression, sym.ReturnsVoid)
                    .WithTrailingTrivia(v.SemicolonToken.TrailingTrivia));
        }

        public override SyntaxNode VisitOperatorDeclaration(OperatorDeclarationSyntax node)
        {
            var v = (OperatorDeclarationSyntax)base.VisitOperatorDeclaration(node);
            if (node.ExpressionBody == null) return v;
            return v.WithExpressionBody(null).WithSemicolonToken(default)
                .WithBody(BlockFor(v.ExpressionBody.Expression, false)
                    .WithTrailingTrivia(v.SemicolonToken.TrailingTrivia));
        }

        public override SyntaxNode VisitConversionOperatorDeclaration(ConversionOperatorDeclarationSyntax node)
        {
            var v = (ConversionOperatorDeclarationSyntax)base.VisitConversionOperatorDeclaration(node);
            if (node.ExpressionBody == null) return v;
            return v.WithExpressionBody(null).WithSemicolonToken(default)
                .WithBody(BlockFor(v.ExpressionBody.Expression, false)
                    .WithTrailingTrivia(v.SemicolonToken.TrailingTrivia));
        }

        public override SyntaxNode VisitConstructorDeclaration(ConstructorDeclarationSyntax node)
        {
            var v = (ConstructorDeclarationSyntax)base.VisitConstructorDeclaration(node);
            if (node.ExpressionBody == null) return v;
            return v.WithExpressionBody(null).WithSemicolonToken(default)
                .WithBody(BlockFor(v.ExpressionBody.Expression, true)
                    .WithTrailingTrivia(v.SemicolonToken.TrailingTrivia));
        }

        public override SyntaxNode VisitPropertyDeclaration(PropertyDeclarationSyntax node)
        {
            var v = (PropertyDeclarationSyntax)base.VisitPropertyDeclaration(node);
            if (node.ExpressionBody == null || !Plain(node.ExpressionBody.Expression) || node.Type is RefTypeSyntax)
                return v;
            var get = AccessorDeclaration(SyntaxKind.GetAccessorDeclaration, BlockFor(v.ExpressionBody.Expression, false));
            return v.WithExpressionBody(null).WithSemicolonToken(default)
                .WithAccessorList(AccessorList(SingletonList(get)).NormalizeWhitespace()
                    .WithTrailingTrivia(v.SemicolonToken.TrailingTrivia));
        }

        public override SyntaxNode VisitIndexerDeclaration(IndexerDeclarationSyntax node)
        {
            var v = (IndexerDeclarationSyntax)base.VisitIndexerDeclaration(node);
            if (node.ExpressionBody == null || !Plain(node.ExpressionBody.Expression) || node.Type is RefTypeSyntax)
                return v;
            var get = AccessorDeclaration(SyntaxKind.GetAccessorDeclaration, BlockFor(v.ExpressionBody.Expression, false));
            return v.WithExpressionBody(null).WithSemicolonToken(default)
                .WithAccessorList(AccessorList(SingletonList(get)).NormalizeWhitespace()
                    .WithTrailingTrivia(v.SemicolonToken.TrailingTrivia));
        }

        public override SyntaxNode VisitAccessorDeclaration(AccessorDeclarationSyntax node)
        {
            var v = (AccessorDeclarationSyntax)base.VisitAccessorDeclaration(node);
            if (node.ExpressionBody == null || !Plain(node.ExpressionBody.Expression)) return v;
            bool isGet = node.Kind() == SyntaxKind.GetAccessorDeclaration;
            return v.WithExpressionBody(null).WithSemicolonToken(default)
                .WithBody(BlockFor(v.ExpressionBody.Expression, !isGet)
                    .WithTrailingTrivia(v.SemicolonToken.TrailingTrivia));
        }

        public override SyntaxNode VisitSimpleLambdaExpression(SimpleLambdaExpressionSyntax node)
        {
            var v = (SimpleLambdaExpressionSyntax)base.VisitSimpleLambdaExpression(node);
            if (node.ExpressionBody == null || node.Modifiers.Any(SyntaxKind.AsyncKeyword) ||
                m.GetSymbolInfo(node).Symbol is not IMethodSymbol ms)
                return v;
            return v.WithExpressionBody(null).WithBlock(BlockFor(v.ExpressionBody, ms.ReturnsVoid));
        }

        public override SyntaxNode VisitParenthesizedLambdaExpression(ParenthesizedLambdaExpressionSyntax node)
        {
            var v = (ParenthesizedLambdaExpressionSyntax)base.VisitParenthesizedLambdaExpression(node);
            if (node.ExpressionBody == null || node.Modifiers.Any(SyntaxKind.AsyncKeyword) ||
                m.GetSymbolInfo(node).Symbol is not IMethodSymbol ms)
                return v;
            return v.WithExpressionBody(null).WithBlock(BlockFor(v.ExpressionBody, ms.ReturnsVoid));
        }
    }

    // --- expr-bodies ------------------------------------------------------------

    // The reverse: a body of one `return e;` (or one statement of a void member)
    // becomes `=> e;`.
    sealed class ExprBodiesRw : CSharpSyntaxRewriter
    {
        static ExpressionSyntax Single(BlockSyntax b, bool allowStatement)
        {
            if (b == null || b.Statements.Count != 1) return null;
            switch (b.Statements[0])
            {
                case ReturnStatementSyntax r when r.Expression != null && !(r.Expression is RefExpressionSyntax):
                    return r.Expression;
                case ExpressionStatementSyntax es when allowStatement:
                    return es.Expression;
                case ThrowStatementSyntax ts when ts.Expression != null:
                    return ThrowExpression(ts.Expression);
                default:
                    return null;
            }
        }

        static ArrowExpressionClauseSyntax Arrow(ExpressionSyntax e) =>
            ArrowExpressionClause(e.WithoutTrivia()).WithLeadingTrivia(Space);

        public override SyntaxNode VisitMethodDeclaration(MethodDeclarationSyntax node)
        {
            var v = (MethodDeclarationSyntax)base.VisitMethodDeclaration(node);
            if (node.Modifiers.Any(SyntaxKind.AsyncKeyword) || node.ReturnType is RefTypeSyntax) return v;
            bool isVoid = node.ReturnType is PredefinedTypeSyntax p && p.Keyword.IsKind(SyntaxKind.VoidKeyword);
            var e = Single(v.Body, isVoid);
            if (e == null) return v;
            if (e is ThrowExpressionSyntax == false && v.Body.Statements[0] is ExpressionStatementSyntax && !isVoid)
                return v;
            return v.WithBody(null).WithExpressionBody(Arrow(e))
                .WithSemicolonToken(Token(SyntaxKind.SemicolonToken).WithTrailingTrivia(v.Body.GetTrailingTrivia()));
        }

        public override SyntaxNode VisitPropertyDeclaration(PropertyDeclarationSyntax node)
        {
            var v = (PropertyDeclarationSyntax)base.VisitPropertyDeclaration(node);
            if (node.Type is RefTypeSyntax || v.AccessorList == null || v.AccessorList.Accessors.Count != 1) return v;
            var acc = v.AccessorList.Accessors[0];
            if (!acc.IsKind(SyntaxKind.GetAccessorDeclaration)) return v;
            ExpressionSyntax e = acc.ExpressionBody?.Expression ?? Single(acc.Body, false);
            if (e == null) return v;
            return v.WithAccessorList(null).WithExpressionBody(Arrow(e))
                .WithSemicolonToken(Token(SyntaxKind.SemicolonToken).WithTrailingTrivia(v.AccessorList.GetTrailingTrivia()));
        }
    }

    // --- explicit-types ---------------------------------------------------------

    // `var x = ...` -> `T x = ...`, in locals, `for`, `foreach`, `using` and `out var`.
    sealed class ExplicitTypesRw : CSharpSyntaxRewriter
    {
        readonly SemanticModel m;
        public ExplicitTypesRw(SemanticModel m) { this.m = m; }

        public override SyntaxNode VisitVariableDeclaration(VariableDeclarationSyntax node)
        {
            var v = (VariableDeclarationSyntax)base.VisitVariableDeclaration(node);
            if (!node.Type.IsVar) return v;
            var d = Display(m, m.GetTypeInfo(node.Type).Type, node.SpanStart);
            return d == null ? v : v.WithType(ParseTypeName(d).WithTriviaFrom(v.Type));
        }

        public override SyntaxNode VisitForEachStatement(ForEachStatementSyntax node)
        {
            var v = (ForEachStatementSyntax)base.VisitForEachStatement(node);
            if (!node.Type.IsVar) return v;
            var d = Display(m, (m.GetDeclaredSymbol(node) as ILocalSymbol)?.Type, node.SpanStart);
            return d == null ? v : v.WithType(ParseTypeName(d).WithTriviaFrom(v.Type));
        }

        public override SyntaxNode VisitDeclarationExpression(DeclarationExpressionSyntax node)
        {
            var v = (DeclarationExpressionSyntax)base.VisitDeclarationExpression(node);
            if (!node.Type.IsVar || !(node.Designation is SingleVariableDesignationSyntax)) return v;
            var d = Display(m, m.GetTypeInfo(node.Type).Type, node.SpanStart);
            return d == null ? v : v.WithType(ParseTypeName(d).WithTriviaFrom(v.Type));
        }
    }

    // --- use-var ----------------------------------------------------------------

    // `T x = new T()` -> `var x = new T()`, where the initializer's own type is `T`.
    sealed class UseVarRw : CSharpSyntaxRewriter
    {
        readonly SemanticModel m;
        public UseVarRw(SemanticModel m) { this.m = m; }

        static bool Natural(ExpressionSyntax e)
        {
            switch (e.Kind())
            {
                case SyntaxKind.ObjectCreationExpression:
                case SyntaxKind.ArrayCreationExpression:
                case SyntaxKind.InvocationExpression:
                case SyntaxKind.IdentifierName:
                case SyntaxKind.SimpleMemberAccessExpression:
                case SyntaxKind.ElementAccessExpression:
                case SyntaxKind.CastExpression:
                case SyntaxKind.NumericLiteralExpression:
                case SyntaxKind.StringLiteralExpression:
                case SyntaxKind.CharacterLiteralExpression:
                case SyntaxKind.TrueLiteralExpression:
                case SyntaxKind.FalseLiteralExpression:
                case SyntaxKind.AddExpression:
                case SyntaxKind.SubtractExpression:
                case SyntaxKind.MultiplyExpression:
                case SyntaxKind.DivideExpression:
                case SyntaxKind.EqualsExpression:
                case SyntaxKind.LessThanExpression:
                case SyntaxKind.GreaterThanExpression:
                    return true;
                default:
                    return false;
            }
        }

        public override SyntaxNode VisitVariableDeclaration(VariableDeclarationSyntax node)
        {
            var v = (VariableDeclarationSyntax)base.VisitVariableDeclaration(node);
            if (node.Type.IsVar || node.Type is RefTypeSyntax || node.Variables.Count != 1) return v;
            if (node.Parent is LocalDeclarationStatementSyntax ld && ld.Modifiers.Any(SyntaxKind.ConstKeyword)) return v;
            if (!(node.Parent is LocalDeclarationStatementSyntax || node.Parent is ForStatementSyntax ||
                  node.Parent is UsingStatementSyntax))
                return v;
            var init = node.Variables[0].Initializer?.Value;
            if (init == null || !Natural(init)) return v;
            var declared = m.GetTypeInfo(node.Type).Type;
            var actual = m.GetTypeInfo(init).Type;
            if (declared == null || actual == null || declared.TypeKind == TypeKind.Error ||
                !SymbolEqualityComparer.Default.Equals(declared, actual))
                return v;
            return v.WithType(IdentifierName("var").WithTriviaFrom(v.Type));
        }
    }

    // --- parens -----------------------------------------------------------------

    // Parentheses around every binary, conditional and cast expression.
    sealed class ParensRw : CSharpSyntaxRewriter
    {
        static SyntaxNode Wrap(ExpressionSyntax original, ExpressionSyntax rewritten) =>
            original.Parent is ParenthesizedExpressionSyntax
                ? rewritten
                : ParenthesizedExpression(rewritten.WithoutTrivia()).WithTriviaFrom(original);

        public override SyntaxNode VisitBinaryExpression(BinaryExpressionSyntax node) =>
            Wrap(node, (ExpressionSyntax)base.VisitBinaryExpression(node));

        public override SyntaxNode VisitConditionalExpression(ConditionalExpressionSyntax node) =>
            Wrap(node, (ExpressionSyntax)base.VisitConditionalExpression(node));

        public override SyntaxNode VisitCastExpression(CastExpressionSyntax node) =>
            Wrap(node, (ExpressionSyntax)base.VisitCastExpression(node));
    }

    // --- qualify ----------------------------------------------------------------

    // `List<int>` -> `System.Collections.Generic.List<int>`: every top-level type
    // named by its simple name gets its namespace.
    sealed class QualifyRw : CSharpSyntaxRewriter
    {
        readonly SemanticModel m;
        public QualifyRw(SemanticModel m) { this.m = m; }

        public override SyntaxNode VisitIdentifierName(IdentifierNameSyntax node) =>
            Qualify(node, (SimpleNameSyntax)base.VisitIdentifierName(node));

        public override SyntaxNode VisitGenericName(GenericNameSyntax node) =>
            Qualify(node, (SimpleNameSyntax)base.VisitGenericName(node));

        SyntaxNode Qualify(SimpleNameSyntax original, SimpleNameSyntax rewritten)
        {
            if (original is IdentifierNameSyntax { IsVar: true }) return rewritten;
            // `nint` and `nuint` are keywords for System.IntPtr and UIntPtr, not names.
            if (original.Identifier.ValueText is "nint" or "nuint") return rewritten;
            var p = original.Parent;
            if (p is MemberAccessExpressionSyntax ma && ma.Name == original) return rewritten;
            if (p is QualifiedNameSyntax q && q.Right == original) return rewritten;
            if (p is AliasQualifiedNameSyntax || p is NameColonSyntax || p is NameEqualsSyntax ||
                p is MemberBindingExpressionSyntax || p is ArgumentSyntax)
                return rewritten;
            foreach (var anc in original.Ancestors())
                if (anc is UsingDirectiveSyntax || anc is AttributeSyntax) return rewritten;
            if (m.GetAliasInfo(original) != null) return rewritten;
            if (!(m.GetSymbolInfo(original).Symbol is INamedTypeSymbol t) || t.ContainingType != null ||
                t.IsAnonymousType || t.TypeKind == TypeKind.TypeParameter ||
                t.ContainingNamespace == null || t.ContainingNamespace.IsGlobalNamespace)
                return rewritten;
            var ns = t.ContainingNamespace.ToDisplayString();
            var bare = rewritten.WithoutTrivia();
            if (p is MemberAccessExpressionSyntax outer && outer.Expression == original)
                return MemberAccessExpression(SyntaxKind.SimpleMemberAccessExpression,
                    ParseExpression(ns), bare).WithTriviaFrom(original);
            return QualifiedName(ParseName(ns), bare).WithTriviaFrom(original);
        }
    }
}
