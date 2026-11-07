//
//  FMiOS4JSON.m
//  Retrofy
//
//  A small JSON parser with NSJSONSerialization's interface, which only exists since iOS 5.
//

typedef struct {
    const unsigned char *bytes;
    NSUInteger length;
    NSUInteger position;
} FMJSONReader;

static const NSUInteger FMJSONMaximumDepth = 64;

static id FMJSONReadValue(FMJSONReader *reader, NSUInteger depth);

static void FMJSONSkipSpace(FMJSONReader *reader)
{
    while (reader->position < reader->length) {
        unsigned char c = reader->bytes[reader->position];
        if (c != ' ' && c != '\n' && c != '\r' && c != '\t') return;
        reader->position++;
    }
}

static BOOL FMJSONReadHex4(FMJSONReader *reader, unichar *value)
{
    if (reader->position + 4 > reader->length) return NO;
    unichar result = 0;
    for (NSUInteger index = 0; index < 4; index++) {
        unsigned char c = reader->bytes[reader->position++];
        unsigned digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return NO;
        result = (unichar)(result << 4 | digit);
    }
    *value = result;
    return YES;
}

static NSString *FMJSONStringFromBytes(const unsigned char *bytes, NSUInteger length)
{
    NSString *string = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    return string ?: [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
}

// Expects the position just after the opening quote.
static NSString *FMJSONReadString(FMJSONReader *reader)
{
    NSUInteger start = reader->position;
    NSMutableString *string = nil;

    while (reader->position < reader->length) {
        unsigned char c = reader->bytes[reader->position];
        if (c == '"') {
            NSString *tail = FMJSONStringFromBytes(reader->bytes + start, reader->position - start);
            reader->position++;
            if (!string) return tail;
            if (tail) [string appendString:tail];
            return string;
        }
        if (c != '\\') {
            reader->position++;
            continue;
        }

        if (!string) string = [NSMutableString string];
        NSString *run = FMJSONStringFromBytes(reader->bytes + start, reader->position - start);
        if (run) [string appendString:run];
        reader->position++;
        if (reader->position >= reader->length) return nil;

        unichar escaped;
        unsigned char escape = reader->bytes[reader->position++];
        switch (escape) {
            case '"': case '\\': case '/': escaped = escape; break;
            case 'b': escaped = '\b'; break;
            case 'f': escaped = '\f'; break;
            case 'n': escaped = '\n'; break;
            case 'r': escaped = '\r'; break;
            case 't': escaped = '\t'; break;
            case 'u':
                // Surrogate pairs arrive as two escapes, NSString keeps UTF-16 so they just line up.
                if (!FMJSONReadHex4(reader, &escaped)) return nil;
                break;
            default:
                return nil;
        }
        [string appendString:[NSString stringWithCharacters:&escaped length:1]];
        start = reader->position;
    }
    return nil;
}

static NSNumber *FMJSONReadNumber(FMJSONReader *reader)
{
    NSUInteger start = reader->position;
    BOOL isFloat = NO;
    while (reader->position < reader->length) {
        unsigned char c = reader->bytes[reader->position];
        if (c == '.' || c == 'e' || c == 'E') isFloat = YES;
        else if (!((c >= '0' && c <= '9') || c == '-' || c == '+')) break;
        reader->position++;
    }
    NSUInteger length = reader->position - start;
    if (!length || length > 63) return nil;

    char text[64];
    memcpy(text, reader->bytes + start, length);
    text[length] = 0;
    if (isFloat) return [NSNumber numberWithDouble:strtod(text, NULL)];
    return [NSNumber numberWithLongLong:strtoll(text, NULL, 10)];
}

static BOOL FMJSONReadLiteral(FMJSONReader *reader, const char *literal)
{
    NSUInteger length = strlen(literal);
    if (reader->position + length > reader->length) return NO;
    if (memcmp(reader->bytes + reader->position, literal, length) != 0) return NO;
    reader->position += length;
    return YES;
}

static NSMutableArray *FMJSONReadArray(FMJSONReader *reader, NSUInteger depth)
{
    NSMutableArray *array = [NSMutableArray array];
    FMJSONSkipSpace(reader);
    if (reader->position < reader->length && reader->bytes[reader->position] == ']') {
        reader->position++;
        return array;
    }
    while (YES) {
        id value = FMJSONReadValue(reader, depth + 1);
        if (!value) return nil;
        [array addObject:value];
        FMJSONSkipSpace(reader);
        if (reader->position >= reader->length) return nil;
        unsigned char c = reader->bytes[reader->position++];
        if (c == ']') return array;
        if (c != ',') return nil;
    }
}

static NSMutableDictionary *FMJSONReadObject(FMJSONReader *reader, NSUInteger depth)
{
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    FMJSONSkipSpace(reader);
    if (reader->position < reader->length && reader->bytes[reader->position] == '}') {
        reader->position++;
        return dictionary;
    }
    while (YES) {
        FMJSONSkipSpace(reader);
        if (reader->position >= reader->length || reader->bytes[reader->position] != '"') return nil;
        reader->position++;
        NSString *key = FMJSONReadString(reader);
        if (!key) return nil;

        FMJSONSkipSpace(reader);
        if (reader->position >= reader->length || reader->bytes[reader->position] != ':') return nil;
        reader->position++;

        id value = FMJSONReadValue(reader, depth + 1);
        if (!value) return nil;
        [dictionary setObject:value forKey:key];

        FMJSONSkipSpace(reader);
        if (reader->position >= reader->length) return nil;
        unsigned char c = reader->bytes[reader->position++];
        if (c == '}') return dictionary;
        if (c != ',') return nil;
    }
}

static id FMJSONReadValue(FMJSONReader *reader, NSUInteger depth)
{
    if (depth > FMJSONMaximumDepth) return nil;
    FMJSONSkipSpace(reader);
    if (reader->position >= reader->length) return nil;

    unsigned char c = reader->bytes[reader->position];
    switch (c) {
        case '{':
            reader->position++;
            return FMJSONReadObject(reader, depth);
        case '[':
            reader->position++;
            return FMJSONReadArray(reader, depth);
        case '"':
            reader->position++;
            return FMJSONReadString(reader);
        case 't':
            return FMJSONReadLiteral(reader, "true") ? [NSNumber numberWithBool:YES] : nil;
        case 'f':
            return FMJSONReadLiteral(reader, "false") ? [NSNumber numberWithBool:NO] : nil;
        case 'n':
            return FMJSONReadLiteral(reader, "null") ? [NSNull null] : nil;
        default:
            return FMJSONReadNumber(reader);
    }
}

@implementation NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)options error:(NSError **)error
{
    FMJSONReader reader = {(const unsigned char *)[data bytes], [data length], 0};
    id value = FMJSONReadValue(&reader, 0);
    if (value) FMJSONSkipSpace(&reader);

    BOOL isContainer = [value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]];
    if (!value || reader.position != reader.length || (!isContainer && !(options & NSJSONReadingAllowFragments))) {
        if (error) *error = [NSError errorWithDomain:@"FMJSON" code:3840 userInfo:[NSDictionary dictionaryWithObject:@"Invalid JSON" forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    return value;
}

@end
