use std::io;

pub fn write_response(_status: u16, _headers: &[(String, String)], _body: &[u8]) -> Vec<u8> {
    unimplemented!("filled in task 3")
}

pub fn parse_request(_buf: &[u8]) -> io::Result<Option<()>> {
    unimplemented!("filled in task 3")
}
