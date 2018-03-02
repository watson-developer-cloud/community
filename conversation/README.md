# Features

**Slots: gathering input from users**

- [Ordering pizza - basic](#ordering-pizza-basic)
- [Ordering pizza - advanced](#ordering-pizza-advanced)
- [Ordering pizza - multiple values](#multiple-values)
- [Ordering pizza - confirmation](#confirmation)
- [Ordering pizza - handlers](#handlers)
- [Ordering pizza - optional slots](#ordering-pizza-optional-slots)
- [Ordering pizza - free-form input](#free-form-input)
- [Ordering pizza - FAQ](#ordering-pizza-FAQ)
- [Booking travel - overlapping entities](#ordering-pizza-entity")

**IBM Cloud Functions integration**

- [IBM Cloud Functions integration](#actions)

**Multi-features**
- [Two intents, handlers, pattern entities, counter](#adv-dialog1)

## Ordering pizza

### Basic example <a id="ordering-pizza-basic"></a>

#### Description

[Ordering pizza - basic](pizza-basic.json) is a simple example of the use of slots in Dialog that supports ordering a pizza and choosing the size and toppings.

#### Features demonstrated

- Users can provide all the information in one sentence as in this example:
      
      ```
      User: "I'd like to order a small pepperoni pizza"

- Users can provide the information by answering prompts, like this:

      ```
      User: "I'd like to order a pizza"
      Bot: "What size?"
      User: "Small"
      Bot: "What toppings?"
      User: "Pepperoni"
      
- Even if the users don't follow the prompts, the dialogue captures the information correctly. In this example, the user provides the full information, but not in the order prompted:

      ```
      User: "I'd like to order a pizza"
      Bot: "What size?"
      User: "Pepperoni"
      Bot: "What size?"
      User: "Small"
      
#### Additional information

- If the slots values are set by entities of non-overlapping types, detecting the response is straightforward. For more information about the case when entity values overlap, see [Booking travel - overlapping entities](#booking-travel-overlapping-entities).
- When execution of the node with slots is completed (all slots are filled), a summary can be reported. The result can be stored as part of the responses section of the node with slots or by following nodes.
- When the node with slots is reentered without clearing the variables, the dialog continues without asking for pre-filled values. This might be the correct behavior for continuing. However, if one wants to start from scratch, set the context variables of the node with slots to null before reentering the node with slots (for example, by setting `"context":{"pizza_type":null, "pizza_size":null}`)

The node on the right of the node with slots is executed after completing the slots.

### Advanced example <a id="ordering-pizza-advanced"></a>

#### Description

[Ordering pizza - advanced](pizza-advanced.json) is an example that is derived from [ordering pizza basic](pizza-basic.json). The example uses advanced options (prompts-advanced) to provide more responses for users based on their input.

#### Features demonstrated

Implement these features by customizing at them the slot level.

- Comments and warnings: The system can provide comments and warnings with context so that reactions can be based on user input. For example, `"$Pizza_type is a good choice, but be warned that the pepperoni is very hot".`
- Handling slot-specific help: You can include an arbitrary condition for each response, and so respond to selected intents. For example, #Help intent as a condition for a `Not Found` result of an individual slot.
- Order of handlers: Only one of the prompts will be executed. Make sure that specific conditional prompts precede general ones. For example, `"$pizza_type is an excellent choice. But be careful, pepperoni is very hot!"` should precede `"$pizza_type is an excellent choice".`
- Handling "Not found": You can also respond to invalid input in the `Not found` section. For example, if users do not respond with appropriate answers, you can remind them about the choices: `"You can select one of the following toppings: margherita, pepperoni, quatro formaggi, mexicana, vegetariana."`
- Service-side validation: If a response is possible but not combined with other responses, you can change the condition and output in **Customize**. To invalidate the slot, go to the JSON editor and update the context. For example:
   
      "context": {"pizza_type":null}
      "We do not provide small pizza with cheese because our cheese slices are too big."
    
### Multiple Values

#### Description

[Ordering pizza - multiple values](pizza-toppings-basic.json) is a basic example of using slots with multiple values. The user can provide an arbitrary number of toppings.

#### Features demonstrated

Slots variable can be a simple type of an array.

- Putting an array of entities in context: To copy the whole array, add `.values`. Referring by just the name returns only the first element.

    ```
    `$pizza_toppings=@pizza_toppings.values` returns all elements
    `$pizza_toppings=@pizza_toppings` returns just the first element of @pizza_toppings
    

- Outputting the array: The expression language (SpEL) does not support loops to iterate over the indexes of an array. To print all the values, use operations that handle the whole array. For example, `Example: <? $pizza_toppings.join(', ') ?>`
- Referring to the number of elements of the entity: Operations @pizza_toppings.length differs syntactically for an array in context. For example, `$pizza_toppings.size()`.

#### Additional information

- While it is good to have the bot confirm what was understood, make sure that the prompts work when the user provides all the information in one sentence:

      User: "I want to order a large Margherita with olives"
      Bot: "Got it. A large pizza"
      Bot: "The type of pizza you want is a Margherita."
      Bot: "With extra olives"
      Bot: "Thank you for ordering a large margherita pizza with olives."

### Confirmation

#### Description

[Ordering pizza - confirmation](pizza-confirm.json) demonstrates a confirmation at the end of ordering a pizza. A separate slot (pizza_confirmed) is introduced as the last slot of the node. The prompt summarizes the values taht are filled so far and requests confirmation before leaving the node. Users can correct previously filled slots, confirm that all slots are correct, or cancel and leave the slot without performing an action.

#### Features demonstrated

- Block confirmation and correction authoring patterns.
- Next step confirmation: Child node makes the decision about what to do with the content. It gets the `$pizza_confirmed` flag indicating whether the values are valid and if the following action should follow.
- Confirmed or canceled: The slot values are set to null to permit entering the node with slots again with empty values.

#### Additional information

- We don't have a mechanism for leaving nodes with slots prematurely (before filling all the slots), but might soon.
- If the slot is set to the value that it had before, it is not considered a slot change. Therefore, no match handler can be called even if the value provided in a sentence is a valid value of some slot.

### Handlers 

#### Description

[Ordering pizza - handlers](pizza-handlers.json) demonstrates how general (node) slot handlers can be used if a user's input are not specific to a particular slot or do not provide a value for any other slots. The general slot handlers check if the slot conditions and match handlers are not triggered. If none of the general slot handlers match, the specific slot "No match" handler is checked. The handlers can be found under "Manage handler." The example is derived from `pizza_confirm.json`.

#### Features demonstrated

- General slot handler with #help as condition: You don't need to add help processing at each individual slot. You can provide a shared handler for the whole node.
- Global handling of the node-related operations:
    - Example: #leave_frame (premature leaving the frame).
    - Example: #reset_frame (setting all the slot values to null).
- Specific slot "Match" handlers and slot conditions are checked with precedence: If an entity triggers, corresponding to pizza_confirm, the general slot level handler #exit does not match. This trigger might be a problem when you use the same wording for the condition pizza_confirm slot and for the general slot level #exit. To avoid this, use the general slot handler entirely to exit prematurely from the node and don't provide the option for pizza_confirm.

### Optional slots <a id="ordering-pizza-optional-slots"></a>

#### Description

[Ordering pizza - optional slots](pizza-optional.json) is an example that demonstrates an optional slot feature. An optional slot (pizza_place) collects information about how the user wants to package the order "to stay" or "to go" but does not prompt for this input.

#### Features demonstrated

- Empty prompt: An optional slot is the slot without text in the prompt
- No prompt to user: Users are not asked for the value of the slot. If the users don't fill in the slot, there is no reminder.
- Prompt can be filled: Users can provide the value of the optional slot at any moment of processing the node with slots. The value is then populated:

    ```     
    User: "I want to order a margherita pizza to go" / @pizza_place:go
    ```

- Node with slots interaction completes if all compulsory slots are filled (disregarding the optional slot values).

### Free-form input

#### Description

[Ordering pizza - free-form input](pizza-take-what-you-get.json) is an example that adds a slot to collect the pizza delivery address to `pizza-basic.json`. The address is accepted without any restriction for format of the input.

#### Features demonstrated

- Different slot condition: Setting slot value with a non entity. For example, setting "Check for" value in slot as `!#order&&!@pizza_size&&!@pizza_type`.

Additional information:

- When collecting any input, this can be input.text (or even true as input.text is always true). The problem is that input.text accepts any input, even the phrase that is used for entering the node with slots e.g. "I want to order pizza". It would match the free-form slot and user would not be ever asked for an address.  We can partially avoid the problem by excluding sentences that match the other slots.
- Assign a value to the context variable represented by the slot (pizza_address). Assignment is typically done automatically (as the value of entity is assigned to slot variable by default). In this case, you must assign it manually by going to the three dot menu next to **Save it as** and by replacing `"!#order&&!@pizza_size&&!@pizza_type` with `<?input.text?>`.
- Any change in a slot's "Check for" input line will override this change, so remember to change it back. This is just a partial solution to the problem. If you enter input for other slots with a spelling mistake, it is not accepted by the slot but is happily taken by our greedy input.text slot. The user will then not be asked for the value of address any more, which is bad behavior. Depending on the input, you might set a condition on the free-form slot on an entity to detect the type of input.
- The more reliable way so far for collecting free-form input is to use data collection without using the node with slots. But this will probably change soon.

### FAQ <a id="ordering-pizza-FAQ"></a>

__Description__

[Ordering pizza - FAQ](Pizza_FAQ.json) is an example of using a node with slots for advenced FAQ.
Basic question answering (e.g. FAQ) is a simple mapping of inputs (questions) to outputs (answers).It is implemented by a sequence of nodes triggered by intents representing questions.

In more advanced cases, however, this is not sufficient. To provide  an answer, one needs to collect one or more parameters 
     
            User: "What is your delivery time?"
            Bot: "Where do you want to deliver it to? We deliver to Manhattan, Bronx and Brooklyn." 
            User: "Bronx"             
            Bot: "Delivery time to Bronx is 30 minutes" 
 
__Features demonstrated__

- Using a node with slots for advenced FAQ.

## Booking Travel

### Overlapping entities <a id="booking-travel-overlapping-entities"></a>

#### Description

[Booking Travel - overlapping entities](travel-overlap.json) is an example of a user booking travel to city `X` from city `Y`. The example demonstrates processing multiple slots associated with the overlapping entities. The user should provide origin, destination, and date of a travel. The form contains two slots that are associated with the same entity @sys_location (travel_from and travel_to) and one slot that is filled by unique entity @sys_date (travel_date). The last one is the confirmation slot travel_confirm that uses the concept of confirmation described in `pizza_confirm.json`.

#### Features demonstrated

- User provides information after the prompts:

		User: "Book travel ticket"
		Bot: "Where do you want to travel from?"
		User: "From Prague"
		Bot: "Where do you want to travel to?"
		User: "London tomorrow"
		Bot: "I understand that you want to travel from Prague to London on 2017-06-07. Is that correct?"

#### Additional information

- It gets more tricky if slots are filled by the two entities of the same type. The system has no contextual information, so it will use only the first entity with the information provided. The first slot will be filled and the second slot will be prompted. For example:

		User: "Book travel ticket"
		Bot: "Where do you want to travel from?"
		User: "From Prague to London tomorrow"
		Bot: "Where do you want to travel to?"
		User: "London"
		Bot: "I understand that you want to travel from Prague to London on 2017-06-07. Is that correct?"

- If the user provides the input in the wrong order (for example, "To London from Prague tomorrow"), the value is not assigned correctly. The first entity is London and it is assigned to the first slot (travel_from).
- You might also check whether more entities of the same type are present and take action. For example, you could ask for disambiguation or look for extra clues like "from" and "to".
- If two entities of different types are detected, they are processed correctly (in the previous example travel_date and travel_from).
- The same problem exists when two slots are filled by entities that have overlapping values.

### Ordering pizza - FAQ <a id="ordering-pizza-FAQ"></a>

#### Description

[Ordering pizza - FAQ](Pizza_FAQ.json) is an example of using a node with slots for advenced FAQ.
Basic question answering (e.g. FAQ) is a simple mapping of inputs (questions) to outputs (answers).It is implemented by a sequence of nodes triggered by intents representing questions.

In more advanced cases, however, this is not sufficient. To provide  an answer, one needs to collect one or more parameters 
   
	User: "What is your delivery time?"
	Bot: "Were do you want to deliver it to? We deliver to Manhattan, Bronx and Brooklyn." 
	User: "Bronx"
	Bot: "Delivery time to Bronx is 30 minutes" 

#### Features demonstrated

using a node with slots for advanced FAQ.

### Ordering pizza - overlapping entities <a id="ordering-pizza-entity"></a>

#### Description

[ordering-pizza-entity](pizza_entity.json) is an example demonstrating how the overlapping entities are processed during slot value resolution. The example is derived from pizza_basic.json, two extra slots are added. The first one is collecting a numerical value representing number of pizzas, the second is collecting the date when the pizza shold be delivered. When entering the phrase:
   
	User: "I want to order two large pizza margherita for August 5"

recognized entities are 

	@sys-number:2
	@pizza_size:large
	@pizza_type:margherita
	@sys-date:2017-08-05
	@sys-number:5

Mind that there are two @sys-number values. The first one is number of pizzas and the secon one is part of the date recognized as a number. The second @sys-number is  overlapped with detected date @sys-date. The slot execution algorithm takes into account the fact of overlapping entities and disregards the smaller one (in this case @sys-number:5). Therefore, the assignment of the values is correct though there wold be a disambiguation problem without this feature.

## IBM Cloud Functions integration <a id="actions"></a>

You can import the [cloud-functions-echo](cloud-functions-echo.json) ** file to your Conversation instance as a new workspace. The workspace contains a dialog with a node that calls the Cloud Functions echo action. You can use the "Try it out" pane in the tooling to see how it works. See [Making programmatic calls from a dialog node](https://console.bluemix.net/docs/services/conversation/dialog-actions.html) for more information.

## Multi-features <a id="adv-dialog1"></a>
### Two intents, handlers, pattern entities, counter

#### Description
[Advanced dialog](adv-dialog1.json) is an electronics store tutorial that uses a combination of advanced dialog features. A user can make an order or return an item. 

#### Features demonstrated
Features highlighted are how to disambiguate if a user inputs multiple intents, how to use handlers to exit a slot, how to utilize pattern entities in dialog, and how to add a counter to know when your bot should escalate to an agent or end a conversation. Watch this [video](https://youtu.be/Z_vmzC0tu60) for more detailed information.
