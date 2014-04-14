%% @author root
%% @doc @todo Add description to registrar_util.


-module(imsi_util).

-include("imsi.hrl").

%% ====================================================================
%% API functions
%% ====================================================================

-export([bin_to_hexstr/1, hexstr_to_bin/1]).

bin_to_hexstr(Bin) ->
  lists:flatten([io_lib:format("~2.16.0B", [X]) ||
    X <- binary_to_list(Bin)]).

-spec hexstr_to_bin(binary() | list()) -> binary().
hexstr_to_bin(S) when is_binary(S) ->
    hexstr_to_bin(binary_to_list(S));
hexstr_to_bin(S) ->
  hexstr_to_bin(S, []).
hexstr_to_bin([], Acc) ->
  list_to_binary(lists:reverse(Acc));
hexstr_to_bin([X,Y|T], Acc) ->
  {ok, [V], []} = io_lib:fread("~16u", [X,Y]),
  hexstr_to_bin(T, [V | Acc]).



%% ====================================================================
%% Internal functions
%% ====================================================================

