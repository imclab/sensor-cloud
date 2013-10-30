%% @author Georgios Koutsoumpakis
%%   [www.csproj13.student.it.uu.se]
%% @version 1.0
%% @copyright [Copyright information]
%%
%% @doc == suggest_tests ==
%% This module contains several tests to test the functionallity
%% in the restful API for the autocomplete feature.
%%
%% @end

-module(suggest_tests).
-include_lib("eunit/include/eunit.hrl").

%% ====================================================================
%% API functions
%% ====================================================================
-export([]).

%% ====================================================================
%% Internal functions
%% ====================================================================

-define(SUGGEST_URL, "http://localhost:8000/suggest/").
-define(RESOURCE_URL, "http://localhost:8000/resources/").

%% @doc
%% Function: post_test/0
%% Purpose: Test a post request
%% Returns: ok | {error, term()}
%%
%% @end
-spec post_test() -> ok | {error, term()}.
post_test() ->
	Response1 = post_request(?RESOURCE_URL, "application/json", 
							"{
								\"model\" : \"testsmartphone2\",
								\"tags\" : \"testtag\"
			}"),
	check_returned_code(Response1, 200),
	timer:sleep(800),
	Response2 = get_request(?SUGGEST_URL++"testsmartphone2"),     
	check_returned_code(Response2, 200),
	{ok, {_, _ ,Body}} = Response2,
	?assertEqual(<<"testtag">>,lib_json:get_field(Body, "testsuggest[0].options[0].payload.tags")).


post_and_stream_test() ->
	Response1 = post_request(?RESOURCE_URL, "application/json", 
							"{
								\"model\" : \"test3resource\",
								\"tags\" : \"testtag\"
			}"),
	check_returned_code(Response1, 200),
	{ok, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} = Response1,
	Id = lib_json:get_field(Body, "_id"),
	timer:sleep(800),
	{ok, {{_Version1, 200, _ReasonPhrase1}, _Headers1, _Body1}} = httpc:request(post, {"http://localhost:8000/streams", [],"application/json", "{\"test\" : \"search\",\"resource_id\" : \""++lib_json:to_string(Id)++"\", \"private\" : \"false\", \"tags\":\"test_tag\"}"}, [], []),
	timer:sleep(1000),
	{ok, {{_Version11, 200, _ReasonPhrase11}, _Headers11, _Body11}} = httpc:request(post, {"http://localhost:8000/streams", [],"application/json", "{\"test\" : \"search2\",\"resource_id\" : \""++lib_json:to_string(Id)++"\", \"private\" : \"false\", \"tags\":\"test2\"}"}, [], []),
	timer:sleep(1000),
	Response2 = get_request(?SUGGEST_URL++"test3resource"),
	check_returned_code(Response2, 200),
	{ok, {_, _ ,Body2}} = Response2,
	?assertEqual(<<"testtag">>,lib_json:get_field(Body2, "testsuggest[0].options[0].payload.tags")),
	?assertEqual(true, lib_json:field_value_exists(Body2, "testsuggest[0].options[0].payload.streams[*].tags",<<"test_tag">>)),
	?assertEqual(<<"test2">>, lib_json:get_field_value(Body2, "testsuggest[0].options[0].payload.streams[*].tags",<<"test2">>)).


%% @doc
%% Function: get_suggestion_test/0
%% Purpose: Test a get request for a suggestion
%% Returns: ok | {error, term()}
%%
%% @end
-spec get_suggestion_test() -> ok | {error, term()}.
get_suggestion_test() ->
	Response1 = post_request(?RESOURCE_URL, "application/json", 
							"{
								\"model\" : \"testanother\",
								\"manufacturer\" : \"ericsson\"
			}"),
	check_returned_code(Response1, 200),
	timer:sleep(800),
	Response2 = get_request(?SUGGEST_URL ++ "testanother"),
	check_returned_code(Response2, 200),
	{ok, {_, _ ,Body}} = Response2,
	?assertEqual(<<"ericsson">>,lib_json:get_field(Body, "testsuggest[0].options[0].payload.manufacturer")).


%% @doc
%% Function: get_non_existing_term_test/0
%% Purpose: Test a get request for a model that doesn't exist
%% Returns: ok | {error, term()}
%%
%% @end
-spec get_non_existing_term_test() -> ok | {error, term()}.
get_non_existing_term_test() ->
	Response1 = get_request(?SUGGEST_URL ++ "non-existing-term"),
	check_returned_code(Response1, 404).




%% @doc
%% Function: check_returned_code/0
%% Purpose: Checks if the Response has the correct http return code
%%
%% @end
-spec check_returned_code(string(), integer()) -> ok.
check_returned_code(Response, Code) ->
	{ok, Rest} = Response,
	{Header,_,_} = Rest,
	?assertMatch({_, Code, _}, Header).


post_request(URL, ContentType, Body) -> request(post, {URL, [], ContentType, Body}).

get_request(URL)                     -> request(get,  {URL, []}).

request(Method, Request) ->
	httpc:request(Method, Request, [], []).
