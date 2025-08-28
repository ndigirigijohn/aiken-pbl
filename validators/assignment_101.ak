
// Custom Types Aiken
// This file demonstrates two custom types and a test comparing field values

// First custom type: Person
type Person {
  name: ByteArray,
  age: Int,
  id_number: Int,
}

// Second custom type: Employee  
type Employee {
  employee_name: ByteArray,
  department: ByteArray,
  employee_id: Int,
  years_employed: Int,
}

// Test function to check if the age of a Person equals the years_employed of an Employee
test person_age_equals_employee_years() {
  // Create an instance of Person
  let person = Person { 
    name: "Alice Smith", 
    age: 5, 
    id_number: 12345 
  }
  
  // Create an instance of Employee
  let employee = Employee { 
    employee_name: "Bob Johnson", 
    department: "Engineering", 
    employee_id: 67890, 
    years_employed: 5 
  }
  
  // Test if person's age equals employee's years_employed
  person.age == employee.years_employed
}

// Additional test with different values to demonstrate a failing case
test person_age_not_equals_employee_years() {
  // Create an instance of Person with different age
  let person = Person { 
    name: "Charlie Brown", 
    age: 3, 
    id_number: 11111 
  }
  
  // Create an instance of Employee with different years_employed
  let employee = Employee { 
    employee_name: "Diana Prince", 
    department: "Marketing", 
    employee_id: 22222, 
    years_employed: 7 
  }
  
  // Test if person's age does NOT equal employee's years_employed
  person.age != employee.years_employed
}

// Test using destructuring to access fields
test destructuring_field_comparison() {
  // Create instances
  let person = Person { 
    name: "Eve Wilson", 
    age: 10, 
    id_number: 33333 
  }
  
  let employee = Employee { 
    employee_name: "Frank Miller", 
    department: "Sales", 
    employee_id: 44444, 
    years_employed: 10 
  }
  
  // Destructure to get specific fields
  let Person { age, .. } = person
  let Employee { years_employed, .. } = employee
  
  // Compare the extracted values
  age == years_employed
}