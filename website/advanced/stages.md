---
outline: deep
---

# Stages

Split one unit of work into ordered stages. Everything registered before `nextStage()` is committed before anything registered after it, and `doWork()` runs your own logic, such as a query, between two stages. All stages run inside the same commit, return one `Result` and, with `commitTransaction()`, roll back together.

**Example**

```apex
new DML()
    .toDelete([SELECT Id FROM Account WHERE Name = 'Yesterday'])
    .nextStage()
    .toInsert(new Account(Name = 'Today'))
    .commitTransaction();
```

Within a stage the [dependency graph](/architecture/registration) still decides the order. Stages are for the cases a graph cannot express: an operation that must wait for another operation on the **same** object type, or logic that needs data written by an earlier stage.

## nextStage

Start a new stage. Records registered after this call are committed after every record registered before it.

**Signature**

```apex
Committable nextStage();
```

**Delete before insert**

The default order runs inserts before deletes. When the new rows would collide with the old ones, for example on a unique field, delete them in an earlier stage.

```apex
new DML()
    .toDelete(obsoleteInventory)
    .nextStage()
    .toInsert(todaysInventory)
    .commitTransaction();
```

**Update the same record twice**

Inside one stage, registering the same record twice throws, unless `combineOnDuplicate()` merges the two into one update. In separate stages each update runs, in order, so triggers see both changes.

```apex
new DML()
    .toUpdate(new Account(Id = accountId, Rating = 'Warm'))
    .nextStage()
    .toUpdate(new Account(Id = accountId, Rating = 'Hot'))
    .commitWork();
```

**Relationships across stages**

A record in a later stage can point to a record from an earlier one. The earlier record already has its `Id` when the later stage runs.

```apex
Account account = new Account(Name = 'Acme');

new DML()
    .toInsert(account)
    .nextStage()
    .toInsert(DML.Record(new Contact(LastName = 'Smith')).withRelationship(Contact.AccountId, account))
    .commitWork();
```

## doWork

Run custom logic between two stages. The work runs after every stage registered before it has been committed, so it can query what they wrote. Records it registers on the `Committable` it receives go to the stage that follows it.

**Signature**

```apex
Committable doWork(DML.Work work);
```

```apex
public interface Work {
  void execute(DML.Committable nextStage);
}
```

**Roll up after an update**

```apex
new DML()
    .toUpdate(closedWonOpportunities)
    .doWork(new RollUpWonRevenue(accountIds))
    .commitTransaction();
```

```apex
public class RollUpWonRevenue implements DML.Work {
  private Set<Id> accountIds;

  public RollUpWonRevenue(Set<Id> accountIds) {
    this.accountIds = accountIds;
  }

  public void execute(DML.Committable nextStage) {
    for (AggregateResult row : [
      SELECT AccountId, SUM(Amount) total
      FROM Opportunity
      WHERE AccountId IN :this.accountIds AND StageName = 'Closed Won'
      GROUP BY AccountId
    ]) {
      nextStage.toUpdate(
        new Account(
          Id = (Id) row.get('AccountId'),
          AnnualRevenue = (Decimal) row.get('total')
        )
      );
    }
  }
}
```

Several `doWork()` calls in a row run in order, and each sees what the previous one registered once it is committed.

::: warning
The `Committable` passed to `execute()` only registers records. Calling `nextStage()`, `doWork()`, `discardWork()`, `commitHook()`, `dryRun()`, `commitWork()` or `commitTransaction()` on it throws a `DmlException`.

Configuration methods throw too (`identifier()`, `userMode()`, `systemMode()`, `accessMode()`, `withSharing()`, `withoutSharing()`, `allowPartialSuccess()`, `skipDuplicateRules()`, `includeOperationIdInErrorMessage()`, `combineOnDuplicate()`, `options()` and `chunkSize()`), because they would change the configuration of the stages that are still running. Configure the unit of work before you commit it.
:::

## How stages work with other features

| Feature                                        | Behavior with stages                                                                                                                                                                                          |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `commitTransaction()`                          | One savepoint covers every stage, including work. A failure in any stage rolls all of them back.                                                                                                              |
| `Result`                                       | One result for all stages, merged by operation type and object type.                                                                                                                                          |
| `identifier()` and [mocking](/mocking/mocking) | Apply to every stage, including records registered inside work.                                                                                                                                               |
| [Commit hooks](/advanced/commit-hooks)         | `before()` runs once before the first stage, `after()` once after the last.                                                                                                                                   |
| `dryRun()`                                     | Runs every stage and every work inside its savepoint, then rolls back. Records registered inside work stay queued afterwards, so build a new unit of work instead of committing the same one after a dry run. |
| `discardWork()`                                | Drops all stages and work.                                                                                                                                                                                    |
| `preview()`                                    | Prints the stages, for example `Stage 1 -> Work (RollUpWonRevenue) -> Stage 2`.                                                                                                                               |
| `allowPartialSuccess()`                        | A failed record does not stop later stages.                                                                                                                                                                   |
| `chunkSize()`                                  | Applies within each stage.                                                                                                                                                                                    |

After `commitWork()` the unit of work starts again with a single empty stage.
