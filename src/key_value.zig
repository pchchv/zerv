fn MakeKeyValue(K: type, V: type, equalFn: fn (lhs: K, rhs: K) bool) type {
    return struct {
        len: usize,
        keys: []K,
        values: []V,
    };
}
