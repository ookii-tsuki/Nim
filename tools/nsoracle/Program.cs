// N# semantic conformance oracle - the Roslyn half.
//
// Reads `.ns` files as C# (every test is deliberately valid C#), asks Roslyn to
// resolve them, and prints the same projected facts nsharp/tools/dumpsema.nim
// prints from the N# frontend; nsharp/tests/run_sema.sh diffs the two. Nothing
// here is N#-specific: this is the plain C# meaning, the truth measured against.
//
//   using <ns>                    each `using` directive
//   member <recv>.<name> = <ns> | <ret>
//                                 a member access on a library (non-source) type:
//                                 the declaring type's namespace and the result
//                                 class, for both `x.M` and `Type.M`
//
// A result outside void/int/float/bool/char/string is `other` and is not
// projected. Both blocks are sorted, so the output does not depend on walk order.
//
// `--ledger` prints the skipped accesses instead, one `<recv>.<name> = <reason>`
// per line; run_sema.sh ratchets that list so a blind spot changes only
// deliberately. See nsharp/CONFORMANCE.md.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

static class Program
{
    static int Main(string[] args)
    {
        // `--ledger` prints the skipped accesses instead of the projected facts.
        var ledgerMode = args.Length >= 1 && args[0] == "--ledger";
        var fileArgs = ledgerMode ? args.Skip(1).ToArray() : args;

        if (fileArgs.Length < 1)
        {
            Console.Error.WriteLine(
                "usage: nsoracle [--ledger] <main.ns> [module.ns ...]");
            return 2;
        }

        // Every file is compiled together, but facts are read from the main file
        // alone; a sibling is a dependency and has no projection of its own.
        var trees = new List<SyntaxTree>();
        foreach (var arg in fileArgs)
        {
            var path = Path.GetFullPath(arg);
            string text;
            try
            {
                text = File.ReadAllText(path);
            }
            catch (IOException e)
            {
                Console.Error.WriteLine("nsoracle: " + e.Message);
                return 2;
            }
            trees.Add(CSharpSyntaxTree.ParseText(text, path: path));
        }

        // The running SDK's trusted assemblies, so the measured BCL is the one the
        // tool itself runs on.
        var refs = new List<MetadataReference>();
        var tpa = (string)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES");
        if (tpa != null)
        {
            foreach (var p in tpa.Split(Path.PathSeparator))
            {
                if (p.Length > 0)
                {
                    refs.Add(MetadataReference.CreateFromFile(p));
                }
            }
        }

        var compilation = CSharpCompilation.Create(
            "nsoracle", trees, refs,
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary));

        var main = trees[0];
        var model = compilation.GetSemanticModel(main);
        var root = main.GetRoot();

        var usings = new List<string>();
        var facts = new List<string>();
        var ledger = new List<string>();

        foreach (var u in root.DescendantNodes().OfType<UsingDirectiveSyntax>())
        {
            if (u.Name == null || u.StaticKeyword.RawKind != 0)
            {
                continue;
            }
            usings.Add(u.Alias != null
                ? "using " + u.Alias.Name + " = " + u.Name
                : "using " + u.Name);
        }

        foreach (var ma in root.DescendantNodes().OfType<MemberAccessExpressionSyntax>())
        {
            var name = ma.Name.Identifier.ValueText;
            var sym = model.GetSymbolInfo(ma).Symbol;

            // A member the program itself declares, or anything that is not a
            // method, property or field, names nothing this stage projects.
            if (sym == null ||
                !(sym is IMethodSymbol || sym is IPropertySymbol || sym is IFieldSymbol) ||
                !sym.DeclaringSyntaxReferences.IsEmpty)
            {
                continue;
            }

            // The receiver is a value for an instance access, the declaring type
            // for a static one.
            ITypeSymbol recvType = sym.IsStatic
                ? sym.ContainingType
                : model.GetTypeInfo(ma.Expression).Type;

            var why = SkipReason(sym, recvType);
            if (why != null)
            {
                ledger.Add(LedgerRow(ma, recvType, name) + " = " + why);
                continue;
            }

            var recv = RecvName(recvType);
            var ns = sym.ContainingType?.ContainingNamespace?.ToDisplayString();
            var isVoid = sym is IMethodSymbol mth && mth.ReturnsVoid;
            var ret = sym is IMethodSymbol m2 ? m2.ReturnType
                    : sym is IPropertySymbol pr ? pr.Type
                    : ((IFieldSymbol)sym).Type;
            var token = RetToken(ret, isVoid);
            facts.Add("member " + recv + "." + name + " = " + ns + " | " + token);
        }

        if (ledgerMode)
        {
            var seen = new HashSet<string>();
            var rows = new List<string>();
            foreach (var r in ledger)
            {
                if (seen.Add(r))
                {
                    rows.Add(r);
                }
            }
            rows.Sort(StringComparer.Ordinal);
            foreach (var r in rows)
            {
                Console.Out.WriteLine(r);
            }
            return 0;
        }

        usings.Sort(StringComparer.Ordinal);
        facts.Sort(StringComparer.Ordinal);
        foreach (var u in usings)
        {
            Console.Out.WriteLine(u);
        }
        foreach (var f in facts)
        {
            Console.Out.WriteLine(f);
        }
        return 0;
    }

    // Why a library member access is not projected, or null when it is. Mirrors
    // dumpsema.nim's rules exactly so both sides project the same accesses.
    static string SkipReason(ISymbol sym, ITypeSymbol recvType)
    {
        // A `T?` lowers to an `Option`, whose members live in the intrinsics.
        if (recvType is INamedTypeSymbol nt &&
            nt.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T)
        {
            return "nullable";
        }
        // A member reached through a type parameter is resolved by N# only when the
        // generic is instantiated (Nim checks each instantiation), so neither side
        // projects it.
        if (recvType is ITypeParameterSymbol)
        {
            return "type-parameter-receiver";
        }
        if (RecvName(recvType).Length == 0)
        {
            return "unplaceable";
        }
        var ns = sym.ContainingType?.ContainingNamespace?.ToDisplayString();
        if (string.IsNullOrEmpty(ns) || ns == "<global namespace>")
        {
            return "global-namespace";
        }
        // A result that is itself a type parameter names no class on its own, and
        // the N# side cannot name it either.
        var orig = sym.OriginalDefinition;
        var oret = orig is IMethodSymbol om ? om.ReturnType
                 : orig is IPropertySymbol op ? op.Type
                 : ((IFieldSymbol)orig).Type;
        if (HasTypeParameter(oret))
        {
            return "type-parameter";
        }
        var isVoid = sym is IMethodSymbol mth && mth.ReturnsVoid;
        var ret = sym is IMethodSymbol m2 ? m2.ReturnType
                : sym is IPropertySymbol pr ? pr.Type
                : ((IFieldSymbol)sym).Type;
        if (!Projected(RetToken(ret, isVoid)))
        {
            return "result:other";
        }
        return null;
    }

    // A skipped access as it reads in the ledger: the receiver in the shared
    // vocabulary when it can be placed, else the expression as written.
    static string LedgerRow(MemberAccessExpressionSyntax ma, ITypeSymbol recvType,
                            string name)
    {
        var recv = RecvName(recvType);
        if (recv.Length == 0)
        {
            recv = ma.Expression.ToString();
        }
        return recv + "." + name;
    }

    // The receiver spelled the way the N# frontend spells it: a C# keyword for a
    // built-in, `array` for an array, otherwise the short type name.
    static string RecvName(ITypeSymbol t)
    {
        if (t == null)
        {
            return "";
        }
        if (t is IArrayTypeSymbol)
        {
            return "array";
        }
        // A `T?` lowers to an `Option`, whose members live in the intrinsics.
        if (t.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T)
        {
            return "";
        }
        switch (t.SpecialType)
        {
            case SpecialType.System_Boolean: return "bool";
            case SpecialType.System_Char: return "char";
            case SpecialType.System_String: return "string";
            case SpecialType.System_Object: return "object";
            case SpecialType.System_SByte: return "sbyte";
            case SpecialType.System_Byte: return "byte";
            case SpecialType.System_Int16: return "short";
            case SpecialType.System_UInt16: return "ushort";
            case SpecialType.System_Int32: return "int";
            case SpecialType.System_UInt32: return "uint";
            case SpecialType.System_Int64: return "long";
            case SpecialType.System_UInt64: return "ulong";
            case SpecialType.System_Single: return "float";
            case SpecialType.System_Double: return "double";
            case SpecialType.System_IntPtr: return "nint";
            case SpecialType.System_UIntPtr: return "nuint";
            default: return t.Name;
        }
    }

    // The shared result token: coarse on the numeric axis, exact on value/string/
    // sequence/object. Anything unprojected is `other`.
    static string RetToken(ITypeSymbol t, bool isVoid)
    {
        if (isVoid)
        {
            return "void";
        }
        if (t == null)
        {
            return "other";
        }
        switch (t.SpecialType)
        {
            case SpecialType.System_Boolean: return "bool";
            case SpecialType.System_Char: return "char";
            case SpecialType.System_String: return "string";
            case SpecialType.System_SByte:
            case SpecialType.System_Byte:
            case SpecialType.System_Int16:
            case SpecialType.System_UInt16:
            case SpecialType.System_Int32:
            case SpecialType.System_UInt32:
            case SpecialType.System_Int64:
            case SpecialType.System_UInt64:
            case SpecialType.System_IntPtr:
            case SpecialType.System_UIntPtr: return "int";
            case SpecialType.System_Single:
            case SpecialType.System_Double: return "float";
            default: return "other";
        }
    }

    static bool Projected(string token)
    {
        return token == "void" || token == "int" || token == "float" ||
               token == "bool" || token == "char" || token == "string";
    }

    // True when a type is, or is built from, a type parameter: `T`, `T[]`, `K, V`.
    static bool HasTypeParameter(ITypeSymbol t)
    {
        if (t == null)
        {
            return false;
        }
        if (t is ITypeParameterSymbol)
        {
            return true;
        }
        if (t is IArrayTypeSymbol a)
        {
            return HasTypeParameter(a.ElementType);
        }
        if (t is IPointerTypeSymbol p)
        {
            return HasTypeParameter(p.PointedAtType);
        }
        if (t is INamedTypeSymbol n)
        {
            return n.TypeArguments.Any(HasTypeParameter);
        }
        return false;
    }
}
