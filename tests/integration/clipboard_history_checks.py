"""Assertions for the paged, private clipboard history control protocol."""


def history(query):
    """Read every page of one revision; a short first page cannot hide rows."""
    first = page = query()
    rows = []
    offset = 0
    while True:
        assert page['available'] and not page['locked'], page
        assert (page['instance'], page['revision'], page['total']) == (
            first['instance'], first['revision'], first['total']), page
        assert page['offset'] == offset and page['limit'] == 20, page
        assert page['returned'] == len(page['entries']) <= 20, page
        rows.extend(page['entries'])
        assert page['has_more'] == (len(rows) < first['total']), page
        if not page['has_more']:
            assert page['next_offset'] is None, page
            break
        offset += len(page['entries'])
        assert page['entries'] and page['next_offset'] == offset, page
        page = query('--offset', str(offset), '--limit', '20',
                     '--revision', str(first['revision']), '--instance', first['instance'])
    assert len(rows) == first['total'] and len({row['id'] for row in rows}) == len(rows), rows
    return rows


def hidden(value):
    assert value['locked'] and not value['available'] and value['entries'] == [], value
    assert not value['pending'] and not value['dirty'] and not value['has_more'], value
    for field in ('total', 'offset', 'limit', 'returned', 'next_offset', 'revision', 'instance', 'persistence_error'):
        assert value[field] is None, (field, value)
