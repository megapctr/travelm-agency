module ContentTypes.Json exposing (Json, NestedJson(..), jsonToInternalRep, parseJson)

import Json.Decode as D
import List.NonEmpty
import Parser as P exposing ((|.), (|=), Parser)
import Parser.DeadEnds
import Result.Extra
import Types
import Util


type alias Json =
    List ( String, NestedJson )


type NestedJson
    = Object (List ( String, NestedJson ))
    | StringValue String


type alias FlattenedJson =
    List ( List String, String )


jsonToInternalRep : Json -> Result String Types.Translations
jsonToInternalRep =
    flattenJson
        >> Result.Extra.combineMap
            (\( k, v ) ->
                case P.run parsePlaceholderString v of
                    Ok tValue ->
                        Ok ( Util.keyToName k, tValue )

                    Err err ->
                        Err <| Parser.DeadEnds.deadEndsToString err
            )


parsePlaceholderString : Parser Types.TValue
parsePlaceholderString =
    let
        escapeChars =
            [ '\\', '{' ]

        escapeStrings =
            List.map String.fromChar escapeChars

        untilNextSpecialChar =
            P.chompWhile (\c -> not <| List.member c escapeChars) |> P.getChompedString
    in
    P.loop []
        (\revSegments ->
            untilNextSpecialChar
                |> P.andThen
                    (\text ->
                        P.oneOf
                            [ P.succeed
                                (P.Done <|
                                    List.reverse <|
                                        if String.isEmpty text then
                                            revSegments

                                        else
                                            Types.Text text :: revSegments
                                )
                                |. P.end
                            , P.succeed
                                (\var ->
                                    P.Loop <|
                                        Types.Interpolation var
                                            :: (if String.isEmpty text then
                                                    revSegments

                                                else
                                                    Types.Text text :: revSegments
                                               )
                                )
                                |. P.token "{"
                                |= (P.chompUntil "}" |> P.getChompedString)
                                |. P.token "}"
                            , P.succeed (\escapedChar -> P.Loop <| Types.Text (text ++ escapedChar) :: revSegments)
                                |. P.token "\\"
                                |= P.oneOf
                                    (P.problem "Invalid escaped char"
                                        :: List.map (\c -> P.token c |> P.map (\_ -> c)) escapeStrings
                                    )
                            ]
                    )
        )
        |> P.andThen
            (\segments ->
                case List.NonEmpty.fromList segments of
                    Just nonEmpty ->
                        P.succeed <| Types.concatenateTextSegments nonEmpty

                    Nothing ->
                        P.succeed <| List.NonEmpty.singleton (Types.Text "")
            )


parseJson : String -> Result String Json
parseJson =
    D.decodeString decoder >> Result.mapError D.errorToString


flattenJson : Json -> FlattenedJson
flattenJson =
    List.concatMap <|
        \( key, value ) ->
            case value of
                StringValue str ->
                    [ ( [ key ], str ) ]

                Object innerObj ->
                    List.map (Tuple.mapFirst <| (::) key) <|
                        flattenJson innerObj


decoder : D.Decoder Json
decoder =
    D.keyValuePairs
        (D.oneOf
            [ objectDecoder
            , stringDecoder
            ]
        )


nestedDecoder : D.Decoder NestedJson
nestedDecoder =
    D.oneOf
        [ objectDecoder
        , stringDecoder
        ]


objectDecoder : D.Decoder NestedJson
objectDecoder =
    D.keyValuePairs (D.lazy <| \_ -> nestedDecoder)
        |> D.map Object


stringDecoder =
    D.string |> D.map StringValue
