// What one remote read can be while a sheet draws it.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}
