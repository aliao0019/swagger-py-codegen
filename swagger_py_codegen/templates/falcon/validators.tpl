# -*- coding: utf-8 -*-

{% include '_do_not_change.tpl' %}
from __future__ import absolute_import

import json
from datetime import date
from functools import wraps

import six
import falcon

from werkzeug.datastructures import MultiDict, Headers
from jsonschema import Draft4Validator

from .schemas import (
    validators, filters, scopes, security, merge_default, normalize)


if six.PY3:
    def _remove_characters(text, deletechars):
        return text.translate({ord(x): None for x in deletechars})
else:
    def _remove_characters(text, deletechars):
        return text.translate(None, deletechars)


def _path_to_endpoint(path):
    return _remove_characters(
        path.strip('/').replace('/', '_').replace('-', '_'),
        '{}')


class JSONEncoder(json.JSONEncoder):

    def default(self, o):
        if isinstance(o, date):
            return o.isoformat()
        return json.JSONEncoder.default(self, o)


class FlaskValidatorAdaptor(object):

    def __init__(self, schema):
        self.validator = Draft4Validator(schema)

    def validate_number(self, type_, value):
        try:
            return type_(value)
        except ValueError:
            return value

    def type_convert(self, obj):
        if obj is None:
            return None
        if isinstance(obj, (dict, list)) and not isinstance(obj, MultiDict):
            return obj
        if isinstance(obj, Headers):
            obj = MultiDict(six.iteritems(obj))
        result = dict()

        convert_funs = {
            'integer': lambda v: self.validate_number(int, v[0]),
            'boolean': lambda v: v[0].lower() not in ['n', 'no', 'false', '', '0'],
            'null': lambda v: None,
            'number': lambda v: self.validate_number(float, v[0]),
            'string': lambda v: v[0]
        }

        def convert_array(type_, v):
            func = convert_funs.get(type_, lambda v: v[0])
            return [func([i]) for i in v]

        for k, values in obj.lists():
            prop = self.validator.schema['properties'].get(k, {})
            type_ = prop.get('type')
            fun = convert_funs.get(type_, lambda v: v[0])
            if type_ == 'array':
                item_type = prop.get('items', {}).get('type')
                result[k] = convert_array(item_type, values)
            else:
                result[k] = fun(values)
        return result

    def validate(self, value):
        value = self.type_convert(value)
        errors = {e.path[0]: e.message for e in self.validator.iter_errors(value)}
        return normalize(self.validator.schema, value)[0], errors


def request_validate(req, resp, resource, params):

    endpoint = _path_to_endpoint(req.uri_template)
    # scope
    if (endpoint, req.method) in scopes and not set(
            scopes[(endpoint, req.method)]).issubset(set(security.scopes)):
        falcon.HTTPUnauthorized('403403403')
    # data
    method = req.method
    if method == 'HEAD':
        method = 'GET'
    locations = validators.get((endpoint, method), {})
    options = {}
    for location, schema in six.iteritems(locations):
        value = getattr(req, location, MultiDict())
        if location == 'headers':
            value = {k.capitalize(): v for k, v in value.items()}
        elif location == 'json':
            body = req.stream.read()

            try:
                value = json.loads(body.decode('utf-8'))
            except (ValueError, UnicodeDecodeError):
                raise falcon.HTTPError(falcon.HTTP_753,
                                       'Malformed JSON',
                                       'Could not decode the request body. The '
                                       'JSON was incorrect or not encoded as '
                                       'UTF-8.')
        if value is None:
            value = MultiDict()
        validator = FlaskValidatorAdaptor(schema)
        result, errors = validator.validate(value)
        if errors:
            raise falcon.HTTPUnprocessableEntity('Unprocessable Entity', description=errors)
        options[location] = result
    req.options = options


def response_filter(req, resp, resource):

    endpoint = _path_to_endpoint(req.uri_template)
    method = req.method
    if method == 'HEAD':
        method = 'GET'
    filter = filters.get((endpoint, method), None)
    if not filter:
        return resp

    headers = None
    status = None

    if len(filter) == 1:
        if six.PY3:
            status = list(filter.keys())[0]
        else:
            status = filter.keys()[0]

    schemas = filter.get(status)
    if not schemas:
        # return resp, status, headers
        raise falcon.HTTPInternalServerError(
            'Not defined',
            description='`%d` is not a defined status code.' % status)

    _resp, errors = normalize(schemas['schema'], req.context['result'])
    if schemas['headers']:
        headers, header_errors = normalize(
            {'properties': schemas['headers']}, headers)
        errors.extend(header_errors)
    if errors:
        raise falcon.HTTPInternalServerError(title='Expectation Failed',
                                             description=errors)

    if 'result' not in req.context:
        return
    resp.body = json.dumps(_resp)