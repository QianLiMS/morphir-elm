{-
   Copyright 2020 Morgan Stanley

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}


module Morphir.IR.Value exposing
    ( Value(..), literal, constructor, apply, field, fieldFunction, lambda, letDef, letDestruct, letRec, list, record, reference
    , tuple, variable, ifThenElse, patternMatch, update, unit
    , mapValueAttributes
    , Pattern(..), wildcardPattern, asPattern, tuplePattern, constructorPattern, emptyListPattern, headTailPattern, literalPattern
    , Specification, mapSpecificationAttributes
    , Definition, mapDefinition, mapDefinitionAttributes
    , definitionToSpecification, uncurryApply, collectVariables
    )

{-| This module contains the building blocks of values in the Morphir IR.


# Value

Value is the top level building block for data and logic. See the constructor functions below for details on each node type.

@docs Value, literal, constructor, apply, field, fieldFunction, lambda, letDef, letDestruct, letRec, list, record, reference
@docs tuple, variable, ifThenElse, patternMatch, update, unit
@docs mapValueAttributes


# Pattern

Patterns are used in multiple ways in the IR: they can take apart a structured value into smaller pieces (destructure) and they
can also filter values. The combination of these two features creates a very powerful method tool that can be used in two ways:
destructuring and pattern-matching. Pattern-matching is a combination of destructuring, filtering and branching.

@docs Pattern, wildcardPattern, asPattern, tuplePattern, constructorPattern, emptyListPattern, headTailPattern, literalPattern


# Specification

The specification of what the value or function
is without the actual data or logic behind it.

@docs Specification, mapSpecificationAttributes


# Definition

A definition is the actual data or logic as opposed to a specification
which is just the specification of those. Value definitions can be typed or untyped. Exposed values have to be typed.

@docs Definition, mapDefinition, mapDefinitionAttributes


# Utilities

@docs definitionToSpecification, uncurryApply, collectVariables

-}

import Dict exposing (Dict)
import Morphir.IR.FQName exposing (FQName)
import Morphir.IR.Literal exposing (Literal)
import Morphir.IR.Name exposing (Name)
import Morphir.IR.Type as Type exposing (Type)
import Morphir.ListOfResults as ListOfResults
import Set exposing (Set)
import String


{-| Type that represents a value.
-}
type Value ta va
    = Literal va Literal
    | Constructor va FQName
    | Tuple va (List (Value ta va))
    | List va (List (Value ta va))
    | Record va (List ( Name, Value ta va ))
    | Variable va Name
    | Reference va FQName
    | Field va (Value ta va) Name
    | FieldFunction va Name
    | Apply va (Value ta va) (Value ta va)
    | Lambda va (Pattern va) (Value ta va)
    | LetDefinition va Name (Definition ta va) (Value ta va)
    | LetRecursion va (Dict Name (Definition ta va)) (Value ta va)
    | Destructure va (Pattern va) (Value ta va) (Value ta va)
    | IfThenElse va (Value ta va) (Value ta va) (Value ta va)
    | PatternMatch va (Value ta va) (List ( Pattern va, Value ta va ))
    | UpdateRecord va (Value ta va) (List ( Name, Value ta va ))
    | Unit va


{-| Type that represents a pattern.
-}
type Pattern a
    = WildcardPattern a
    | AsPattern a (Pattern a) Name
    | TuplePattern a (List (Pattern a))
    | ConstructorPattern a FQName (List (Pattern a))
    | EmptyListPattern a
    | HeadTailPattern a (Pattern a) (Pattern a)
    | LiteralPattern a Literal
    | UnitPattern a


{-| Type that represents a value or function specification. The specification of what the value or function
is without the actual data or logic behind it.
-}
type alias Specification ta =
    { inputs : List ( Name, Type ta )
    , output : Type ta
    }


{-| Type that represents a value or function definition. A definition is the actual data or logic as opposed to a specification
which is just the specification of those. Value definitions can be typed or untyped. Exposed values have to be typed.
-}
type alias Definition ta va =
    { inputTypes : List ( Name, va, Type ta )
    , outputType : Type ta
    , body : Value ta va
    }


{-| Turns a definition into a specification by removing implementation details.
-}
definitionToSpecification : Definition ta va -> Specification ta
definitionToSpecification def =
    { inputs =
        def.inputTypes
            |> List.map
                (\( name, _, tpe ) ->
                    ( name, tpe )
                )
    , output =
        def.outputType
    }


{-| -}
mapDefinition : (Type ta -> Result e (Type ta)) -> (Value ta va -> Result e (Value ta va)) -> Definition ta va -> Result (List e) (Definition ta va)
mapDefinition mapType mapValue def =
    Result.map3 (\inputTypes outputType body -> Definition inputTypes outputType body)
        (def.inputTypes
            |> List.map
                (\( name, attr, tpe ) ->
                    mapType tpe
                        |> Result.map
                            (\t ->
                                ( name, attr, t )
                            )
                )
            |> ListOfResults.liftAllErrors
        )
        (mapType def.outputType |> Result.mapError List.singleton)
        (mapValue def.body |> Result.mapError List.singleton)


{-| -}
mapSpecificationAttributes : (a -> b) -> Specification a -> Specification b
mapSpecificationAttributes f spec =
    Specification
        (spec.inputs
            |> List.map
                (\( name, tpe ) ->
                    ( name, Type.mapTypeAttributes f tpe )
                )
        )
        (Type.mapTypeAttributes f spec.output)


{-| -}
mapValueAttributes : (ta -> tb) -> (va -> vb) -> Value ta va -> Value tb vb
mapValueAttributes f g v =
    case v of
        Literal a value ->
            Literal (g a) value

        Constructor a fullyQualifiedName ->
            Constructor (g a) fullyQualifiedName

        Tuple a elements ->
            Tuple (g a) (elements |> List.map (mapValueAttributes f g))

        List a items ->
            List (g a) (items |> List.map (mapValueAttributes f g))

        Record a fields ->
            Record (g a)
                (fields
                    |> List.map
                        (\( fieldName, fieldValue ) ->
                            ( fieldName, mapValueAttributes f g fieldValue )
                        )
                )

        Variable a name ->
            Variable (g a) name

        Reference a fullyQualifiedName ->
            Reference (g a) fullyQualifiedName

        Field a subjectValue fieldName ->
            Field (g a) (mapValueAttributes f g subjectValue) fieldName

        FieldFunction a fieldName ->
            FieldFunction (g a) fieldName

        Apply a function argument ->
            Apply (g a) (mapValueAttributes f g function) (mapValueAttributes f g argument)

        Lambda a argumentPattern body ->
            Lambda (g a) (mapPatternAttributes g argumentPattern) (mapValueAttributes f g body)

        LetDefinition a valueName valueDefinition inValue ->
            LetDefinition (g a) valueName (mapDefinitionAttributes f g valueDefinition) (mapValueAttributes f g inValue)

        LetRecursion a valueDefinitions inValue ->
            LetRecursion (g a)
                (valueDefinitions
                    |> Dict.map
                        (\_ def ->
                            mapDefinitionAttributes f g def
                        )
                )
                (mapValueAttributes f g inValue)

        Destructure a pattern valueToDestruct inValue ->
            Destructure (g a) (mapPatternAttributes g pattern) (mapValueAttributes f g valueToDestruct) (mapValueAttributes f g inValue)

        IfThenElse a condition thenBranch elseBranch ->
            IfThenElse (g a) (mapValueAttributes f g condition) (mapValueAttributes f g thenBranch) (mapValueAttributes f g elseBranch)

        PatternMatch a branchOutOn cases ->
            PatternMatch (g a)
                (mapValueAttributes f g branchOutOn)
                (cases
                    |> List.map
                        (\( pattern, body ) ->
                            ( mapPatternAttributes g pattern, mapValueAttributes f g body )
                        )
                )

        UpdateRecord a valueToUpdate fieldsToUpdate ->
            UpdateRecord (g a)
                (mapValueAttributes f g valueToUpdate)
                (fieldsToUpdate
                    |> List.map
                        (\( fieldName, fieldValue ) ->
                            ( fieldName, mapValueAttributes f g fieldValue )
                        )
                )

        Unit a ->
            Unit (g a)


{-| -}
mapPatternAttributes : (a -> b) -> Pattern a -> Pattern b
mapPatternAttributes f p =
    case p of
        WildcardPattern a ->
            WildcardPattern (f a)

        AsPattern a p2 name ->
            AsPattern (f a) (mapPatternAttributes f p2) name

        TuplePattern a elementPatterns ->
            TuplePattern (f a) (elementPatterns |> List.map (mapPatternAttributes f))

        ConstructorPattern a constructorName argumentPatterns ->
            ConstructorPattern (f a) constructorName (argumentPatterns |> List.map (mapPatternAttributes f))

        EmptyListPattern a ->
            EmptyListPattern (f a)

        HeadTailPattern a headPattern tailPattern ->
            HeadTailPattern (f a) (mapPatternAttributes f headPattern) (mapPatternAttributes f tailPattern)

        LiteralPattern a value ->
            LiteralPattern (f a) value

        UnitPattern a ->
            UnitPattern (f a)


{-| -}
mapDefinitionAttributes : (ta -> tb) -> (va -> vb) -> Definition ta va -> Definition tb vb
mapDefinitionAttributes f g d =
    Definition
        (d.inputTypes |> List.map (\( name, attr, tpe ) -> ( name, g attr, Type.mapTypeAttributes f tpe )))
        (Type.mapTypeAttributes f d.outputType)
        (mapValueAttributes f g d.body)


{-| Collect all variables in a value recursively.
-}
collectVariables : Value ta va -> Set Name
collectVariables value =
    let
        collectUnion : List (Value ta va) -> Set Name
        collectUnion values =
            values
                |> List.map collectVariables
                |> List.foldl Set.union Set.empty
    in
    case value of
        Tuple _ elements ->
            collectUnion elements

        List _ items ->
            collectUnion items

        Record _ fields ->
            collectUnion (fields |> List.map Tuple.second)

        Variable _ name ->
            Set.singleton name

        Field _ subjectValue _ ->
            collectVariables subjectValue

        Apply _ function argument ->
            collectUnion [ function, argument ]

        Lambda _ _ body ->
            collectVariables body

        LetDefinition _ valueName valueDefinition inValue ->
            collectUnion [ valueDefinition.body, inValue ]
                |> Set.insert valueName

        LetRecursion _ valueDefinitions inValue ->
            List.foldl Set.union
                Set.empty
                (valueDefinitions
                    |> Dict.toList
                    |> List.map
                        (\( defName, def ) ->
                            collectVariables def.body
                                |> Set.insert defName
                        )
                    |> List.append [ collectVariables inValue ]
                )

        Destructure _ _ valueToDestruct inValue ->
            collectUnion [ valueToDestruct, inValue ]

        IfThenElse _ condition thenBranch elseBranch ->
            collectUnion [ condition, thenBranch, elseBranch ]

        PatternMatch _ branchOutOn cases ->
            collectUnion (cases |> List.map Tuple.second)
                |> Set.union (collectVariables branchOutOn)

        UpdateRecord _ valueToUpdate fieldsToUpdate ->
            collectUnion (fieldsToUpdate |> List.map Tuple.second)
                |> Set.union (collectVariables valueToUpdate)

        _ ->
            Set.empty



--rewriteValue : Rewrite e (Value a)
--rewriteValue rewriteBranch rewriteLeaf valueToRewrite =
--    case valueToRewrite of
--        Tuple a elements ->
--            elements
--                |> List.map rewriteBranch
--                |> ResultList.liftLastError
--                |> Result.map (Tuple a)
--
--        List a items ->
--            items
--                |> List.map rewriteBranch
--                |> ResultList.liftLastError
--                |> Result.map (List a)
--
--        Record a fields ->
--            fields
--                |> List.map
--                    (\( fieldName, fieldValue ) ->
--                        rewriteBranch fieldValue
--                            |> Result.map (Tuple.pair fieldName)
--                    )
--                |> ResultList.liftLastError
--                |> Result.map (Record a)
--
--        Field a subjectValue fieldName ->
--            rewriteBranch subjectValue
--                |> Result.map
--                    (\subject ->
--                        Field a subject fieldName
--                    )
--
--        Apply a function argument ->
--            Result.map2 (Apply a)
--                (rewriteBranch function)
--                (rewriteBranch argument)
--
--        Lambda a argumentPattern body ->
--            Lambda (f a) (mapPatternAttributes f argumentPattern) (mapValueAttributes f body)
--
--        LetDefinition a valueName valueDefinition inValue ->
--            LetDefinition (f a) valueName (mapDefinitionAttributes f valueDefinition) (mapValueAttributes f inValue)
--
--        LetRecursion a valueDefinitions inValue ->
--            LetRecursion (f a)
--                (valueDefinitions
--                    |> List.map
--                        (\( name, def ) ->
--                            ( name, mapDefinitionAttributes f def )
--                        )
--                )
--                (mapValueAttributes f inValue)
--
--        Destructure a pattern valueToDestruct inValue ->
--            Destructure (f a) (mapPatternAttributes f pattern) (mapValueAttributes f valueToDestruct) (mapValueAttributes f inValue)
--
--        IfThenElse a condition thenBranch elseBranch ->
--            IfThenElse (f a) (mapValueAttributes f condition) (mapValueAttributes f thenBranch) (mapValueAttributes f elseBranch)
--
--        PatternMatch a branchOutOn cases ->
--            PatternMatch (f a)
--                (mapValueAttributes f branchOutOn)
--                (cases
--                    |> List.map
--                        (\( pattern, body ) ->
--                            ( mapPatternAttributes f pattern, mapValueAttributes f body )
--                        )
--                )
--
--        UpdateRecord a valueToUpdate fieldsToUpdate ->
--            UpdateRecord (f a)
--                (mapValueAttributes f valueToUpdate)
--                (fieldsToUpdate
--                    |> List.map
--                        (\( fieldName, fieldValue ) ->
--                            ( fieldName, mapValueAttributes f fieldValue )
--                        )
--                )
--
--        _ ->
--            rewriteLeaf valueToRewrite


{-| A [literal][lit] represents a fixed value in the IR. We only allow values of basic types: bool, char, string, int, float.

    True -- Literal (BoolLiteral True)

    'a' -- Literal (CharLiteral 'a')

    "foo" -- Literal (StringLiteral "foo")

    13 -- Literal (IntLiteral 13)

    15.4 -- Literal (FloatLiteral 15.4)

[lit]: https://en.wikipedia.org/wiki/Literal_(computer_programming)

-}
literal : va -> Literal -> Value ta va
literal attributes value =
    Literal attributes value


{-| A reference to a constructor of a custom type.

    Nothing -- Constructor ( ..., [ [ "maybe" ] ], [ "nothing" ] )

    Foo.Bar -- Constructor ( ..., [ [ "foo" ] ], [ "bar" ] )

-}
constructor : va -> FQName -> Value ta va
constructor attributes fullyQualifiedName =
    Constructor attributes fullyQualifiedName


{-| A [tuple] represents an ordered list of values where each value can be of a different type.

**Note**: Tuples with zero values are considered to be the special value [`Unit`](#unit)

    ( 1, True ) -- Tuple [ Literal (IntLiteral 1), Literal (BoolLiteral True) ]

    ( "foo", True, 3 ) -- Tuple [ Literal (StringLiteral "foo"), Literal (BoolLiteral True), Literal (IntLiteral 3) ]

    () -- Unit

[tuple]: https://en.wikipedia.org/wiki/Tuple

-}
tuple : va -> List (Value ta va) -> Value ta va
tuple attributes elements =
    Tuple attributes elements


{-| A [list] represents an ordered list of values where every value has to be of the same type.

    [ 1, 3, 5 ] -- List [ Literal (IntLiteral 1), Literal (IntLiteral 3), Literal (IntLiteral 5) ]

    [] -- List []

[list]: https://en.wikipedia.org/wiki/List_(abstract_data_type)

-}
list : va -> List (Value ta va) -> Value ta va
list attributes items =
    List attributes items


{-| A [record] represents a list of fields where each field has a name and a value.

    { foo = "bar" } -- Record [ ( [ "foo" ], Literal (StringLiteral "bar") ) ]

    { foo = "bar", baz = 1 } -- Record [ ( [ "foo" ], Literal (StringLiteral "bar") ), ( [ "baz" ], Literal (IntLiteral 1) ) ]

    {} -- Record []

[record]: https://en.wikipedia.org/wiki/Record_(computer_science)

-}
record : va -> List ( Name, Value ta va ) -> Value ta va
record attributes fields =
    Record attributes fields


{-| A [variable] represents a reference to a named value in the scope.

    a -- Variable [ "a" ]

    fooBar15 -- Variable [ "foo", "bar", "15" ]

[variable]: https://en.wikipedia.org/wiki/Variable_(computer_science)

-}
variable : va -> Name -> Value ta va
variable attributes name =
    Variable attributes name


{-| A reference that refers to a function or a value with its fully-qualified name.

    List.map -- Reference ( [ ..., [ [ "list" ] ], [ "map" ] )

-}
reference : va -> FQName -> Value ta va
reference attributes fullyQualifiedName =
    Reference attributes fullyQualifiedName


{-| Extracts the value of a record's field.

    a.foo -- Field (Variable [ "a" ]) [ "foo" ]

-}
field : va -> Value ta va -> Name -> Value ta va
field attributes subjectValue fieldName =
    Field attributes subjectValue fieldName


{-| Represents a function that extract a field from a record value passed to it.

    .foo -- FieldFunction [ "foo" ]

-}
fieldFunction : va -> Name -> Value ta va
fieldFunction attributes fieldName =
    FieldFunction attributes fieldName


{-| Represents a function invocation. We use currying to represent function invocations with multiple arguments.

**Note**: Operators are mapped to well-known function names.

    not True -- Apply (Reference ( ..., [ [ "basics" ] ], [ "not" ])) (Literal (BoolLiteral True))

    True || False -- Apply (Apply (Reference ( ..., [ [ "basics" ] ], [ "and" ]))) (Literal (BoolLiteral True)) (Literal (BoolLiteral True))

-}
apply : va -> Value ta va -> Value ta va -> Value ta va
apply attributes function argument =
    Apply attributes function argument


{-| Represents a lambda abstraction.

**Note**:

  - We use currying to represent lambda abstractions with multiple arguments.
  - Arguments are not just names, they are patterns.

```
\a -> a -- Lambda (AsPattern WildcardPattern [ "a" ]) (Variable [ "a" ])

\a b -> a -- Lambda (AsPattern WildcardPattern [ "a" ]) (Lambda (AsPattern WildcardPattern [ "b" ]) (Variable [ "a" ]))
```

-}
lambda : va -> Pattern va -> Value ta va -> Value ta va
lambda attributes argumentPattern body =
    Lambda attributes argumentPattern body


{-| Represents a let expression that assigns a value (and optionally type) to a name.

**Note**: We use currying to represent let expressions with multiple name bindings.

    let
        a =
            b
    in
    a
    -- LetDef [ "a" ]
    --     (UntypedDefinition [] (Variable [ "b" ]))
    --     (Variable [ "a" ])

    let
        a : Bool
        a =
            b

        c x =
            a
    in
    c
    -- LetDef [ "a" ]
    --     (TypedDefinition (Basic BoolType) [] (Variable [ "b" ]))
    --     (LetDef [ "c" ]
    --         (UntypedDefinition [ [ "x" ] ] (Variable [ "a" ]))
    --         (Variable [ "c" ])
    --     )

-}
letDef : va -> Name -> Definition ta va -> Value ta va -> Value ta va
letDef attributes valueName valueDefinition inValue =
    LetDefinition attributes valueName valueDefinition inValue


{-| Represents a let expression with one or many recursive definitions.

    let
        a =
            b

        b =
            a
    in
    a
    -- LetRec
    --     [ ( [ "a" ], UntypedDefinition [] (Variable [ "b" ]) )
    --     , ( [ "b" ], UntypedDefinition [] (Variable [ "a" ]) )
    --     ]
    --     (Variable [ "a" ])

-}
letRec : va -> Dict Name (Definition ta va) -> Value ta va -> Value ta va
letRec attributes valueDefinitions inValue =
    LetRecursion attributes valueDefinitions inValue


{-| Represents a let expression that extracts values using a pattern.

    let
        ( a, b ) =
            c
    in
    a
    -- LetDestruct
    --     (TuplePattern [ AsPattern WildcardPattern ["a"], AsPattern WildcardPattern ["b"] ])
    --     (Variable ["a"])

-}
letDestruct : va -> Pattern va -> Value ta va -> Value ta va -> Value ta va
letDestruct attributes pattern valueToDestruct inValue =
    Destructure attributes pattern valueToDestruct inValue


{-| Represents and if/then/else expression.

    if a then
        b
    else
        c
    -- IfThenElse (Variable ["a"])
    --     (Variable ["b"])
    --     (Variable ["c"])

-}
ifThenElse : va -> Value ta va -> Value ta va -> Value ta va -> Value ta va
ifThenElse attributes condition thenBranch elseBranch =
    IfThenElse attributes condition thenBranch elseBranch


{-| Represents a pattern-match.

    case a of
        1 ->
            "yea"

        _ ->
            "nay"
    -- PatternMatch (Variable ["a"])
    --     [ ( LiteralPattern (IntLiteral 1), Literal (StringLiteral "yea") )
    --     , ( WildcardPattern, Literal (StringLiteral "nay") )
    --     ]

-}
patternMatch : va -> Value ta va -> List ( Pattern va, Value ta va ) -> Value ta va
patternMatch attributes branchOutOn cases =
    PatternMatch attributes branchOutOn cases


{-| Update one or many fields of a record value.

    { a | foo = 1 } -- Update (Variable ["a"]) [ ( ["foo"], Literal (IntLiteral 1) ) ]

-}
update : va -> Value ta va -> List ( Name, Value ta va ) -> Value ta va
update attributes valueToUpdate fieldsToUpdate =
    UpdateRecord attributes valueToUpdate fieldsToUpdate


{-| Represents the unit value.

    () -- Unit

-}
unit : va -> Value ta va
unit attributes =
    Unit attributes


{-| Matches any value and ignores it (assigns no variable name).

    _ -- WildcardPattern

-}
wildcardPattern : a -> Pattern a
wildcardPattern attributes =
    WildcardPattern attributes


{-| Assigns a variable name to a pattern.

    _ as foo -- AsPattern WildcardPattern ["foo"]

    foo -- AsPattern WildcardPattern ["foo"]

    [] as foo -- AsPattern EmptyListPattern ["foo"]

-}
asPattern : a -> Pattern a -> Name -> Pattern a
asPattern attributes pattern name =
    AsPattern attributes pattern name


{-| Destructures a tuple using a pattern for every element.

    ( _, foo ) -- TuplePattern [ WildcardPattern, AsPattern WildcardPattern ["foo"] ]

-}
tuplePattern : a -> List (Pattern a) -> Pattern a
tuplePattern attributes elementPatterns =
    TuplePattern attributes elementPatterns


{-| Matches on a custom type's constructor.

**Note**: When the custom type has a single constructor this can be used for destructuring.
When there are multiple constructors it also does filtering so it cannot be used in a
[`LetDestruct`](#letDestruct) but it can be used in a [pattern-match](#patternMatch).

    Just _ -- ConstructorPattern ( ..., [["maybe"]], ["just"]) [ WildcardPattern ]

-}
constructorPattern : a -> FQName -> List (Pattern a) -> Pattern a
constructorPattern attributes constructorName argumentPatterns =
    ConstructorPattern attributes constructorName argumentPatterns


{-| Matches an empty list. Can be used standalon but frequently used as a terminal pattern
in a [`HeadTailPattern`](#headTailPattern).

    [] -- EmptyListPattern

    [ _ ]
    -- HeadTailPattern
    --     WildcardPattern
    --     EmptyListPattern

-}
emptyListPattern : a -> Pattern a
emptyListPattern attributes =
    EmptyListPattern attributes


{-| Matches the head and the tail of a list. It can be used to match lists of at least N items
by nesting this pattern N times and terminating with [`EmptyListPattern`](#emptyListPattern).

    [ a ]
    -- HeadTailPattern
    --     (AsPattern WildcardPattern ["a"])
    --     EmptyListPattern

    a :: b
    -- HeadTailPattern
    --     (AsPattern WildcardPattern ["a"])
    --     (AsPattern WildcardPattern ["b"])

    [ a, b ]
    -- HeadTailPattern
    --     (AsPattern WildcardPattern ["a"])
    --     (HeadTailPattern
    --         (AsPattern WildcardPattern ["b"])
    --         EmptyListPattern
    --     )

-}
headTailPattern : a -> Pattern a -> Pattern a -> Pattern a
headTailPattern attributes headPattern tailPattern =
    HeadTailPattern attributes headPattern tailPattern


{-| Matches a specific literal value. This pattern can only be used in a [pattern-match](#patternMatch)
since it always filters.

    True -- LiteralPattern (BoolLiteral True)

    'a' -- LiteralPattern (CharLiteral 'a')

    "foo" -- LiteralPattern (StringLiteral "foo")

    13 -- LiteralPattern (IntLiteral 13)

    15.4 -- LiteralPattern (FloatLiteral 15.4)

-}
literalPattern : a -> Literal -> Pattern a
literalPattern attributes value =
    LiteralPattern attributes value


{-| Extract the argument list from a curried apply tree. It takes the two arguments of an apply and returns a tuple of
the function and a list of arguments.

    uncurryApply (Apply () f a) b == ( f, [ a, b ] )

-}
uncurryApply : Value ta va -> Value ta va -> ( Value ta va, List (Value ta va) )
uncurryApply fun lastArg =
    case fun of
        Apply _ nestedFun nestedArg ->
            let
                ( f, initArgs ) =
                    uncurryApply nestedFun nestedArg
            in
            ( f, List.append initArgs [ lastArg ] )

        _ ->
            ( fun, [ lastArg ] )
